{
  description = "ArgoCD with nixidy.";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    systems.url = "github:nix-systems/default";
    nixidy = {
      url = "github:arnarg/nixidy";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixidy,
      systems,
    }:
    let
      forEachSystem =
        f: nixpkgs.lib.genAttrs (import systems) (system: f system nixpkgs.legacyPackages.${system});

      environments = [
        "dev"
        "infra"
      ];
    in
    {
      nixidyEnvs = forEachSystem (
        system: pkgs:
        nixidy.lib.mkEnvs {
          inherit pkgs;
          envs = builtins.listToAttrs (
            map (env: {
              name = env;
              value = {
                modules = [ ./env/${env} ];
              };
            }) environments
          );
          libOverlay = self: old: {
            kube = old.kube // {
              readYamlsFromDir = import ./lib/readYaml.nix { lib = old; };
            };
          };
        }
      );

      packages = forEachSystem (
        system: pkgs: {
          nixidy = nixidy.packages.${system}.default;
          generators.gateway-api = nixidy.packages.${system}.generators.fromCRD {
            name = "gateway-api";
            src = pkgs.fetchFromGitHub {
              owner = "kubernetes-sigs";
              repo = "gateway-api";
              rev = "v1.2.1";
              hash = "sha256-jVW/8RhhZi50xscb/obtMbrDwZRE1BkDqah3rq+Mgvc=";
            };
            crds = [
              "config/crd/standard/gateway.networking.k8s.io_gatewayclasses.yaml"
              "config/crd/standard/gateway.networking.k8s.io_gateways.yaml"
              # "config/crd/standard/gateway.networking.k8s.io_grpcroutes.yaml"
              "config/crd/standard/gateway.networking.k8s.io_httproutes.yaml"
              "config/crd/standard/gateway.networking.k8s.io_referencegrants.yaml"
            ];
          };
        }
      );

      devShells = forEachSystem (
        system: pkgs: {
          default = pkgs.mkShell {
            buildInputs = [ nixidy.packages.${system}.default ];
          };
        }
      );

      apps = forEachSystem (
        system: pkgs:
        let

          build-yamls-fn = ''
            build_yamls() {
              set -e
              # Default to "all" if no argument provided
              local target_env="''${1:-all}"

              # Available environments
              read -r -a available_envs <<< "${builtins.concatStringsSep " " environments}"

              if [ "$target_env" = "all" ]; then
                # Build all environments
                for env in "''${available_envs[@]}"; do
                  echo "Generating App manifests for \"$env\"..."
                  nixidy switch .#"$env"
                  echo "Generating App of Apps for \"$env\"..."
                  nixidy bootstrap .#"$env" > "manifests/$env/bootstrap.yaml"
                done
              else
                # Check if the specified environment exists
                local env_found=false
                for env in "''${available_envs[@]}"; do
                  if [ "$env" = "$target_env" ]; then
                    env_found=true
                    break
                  fi
                done

                if [ "$env_found" = "true" ]; then
                  echo "Generating App manifests for \"$target_env\"..."
                  nixidy switch .#"$target_env"
                  echo "Generating App of Apps for \"$target_env\"..."
                  nixidy bootstrap .#"$target_env" > "manifests/$target_env/bootstrap.yaml"
                else
                  echo "Error: Environment '$target_env' not found."
                  echo "Available environments: ''${available_envs[*]}"
                  exit 1
                fi
              fi
            }
          '';

          sops-operator-manifest = ''
            apiVersion: v1
            kind: Namespace
            metadata:
              name: sops-operator
            ---
            apiVersion: v1
            kind: Namespace
            metadata:
              name: argocd
            ---
            apiVersion: v1
            kind: Secret
            metadata:
              name: age-key
              namespace: sops-operator
            type: Opaque
            data:
              key.txt: __AGE_KEY_BASE64__
          '';

          install-sops-operator-fn = ''
            install_sops_operator() {
              echo "--- Installing sops-secrets-operator ---"
              local age_key_base64
              age_key_base64=$(base64 -w 0 < key.txt)
              echo '${sops-operator-manifest}' | sed "s|__AGE_KEY_BASE64__|''${age_key_base64}|" | kubectl apply -f -
              kubectl apply -f manifests/infra/sops-secrets-operator
              kubectl rollout status -n sops-operator deployment sops-sops-secrets-operator
              echo "✓ sops-secrets-operator installed."
            }
          '';

          install-cert-manager-fn = ''
            install_cert_manager() {
              echo "--- Installing Cert Manager ---"
              kubectl apply -f manifests/infra/k8s-gw-api-crds

              local cm_max_retries=5
              local cm_retry_delay=10
              local issuer_max_retries=3
              local issuer_retry_delay=5
              local i

              for ((i=1; i<=cm_max_retries; i++)); do
                echo "Attempt $i: Applying cert-manager manifests..."
                if kubectl apply -f manifests/infra/cert-manager; then
                  echo "Cert-manager applied successfully. Checking ClusterIssuer 'lab-k8s-ca-issuer' readiness..."
                  local j
                  for ((j=1; j<=issuer_max_retries; j++)); do
                    echo "Attempt $j: Checking if ClusterIssuer 'lab-k8s-ca-issuer' is ready..."
                    if kubectl get clusterissuer lab-k8s-ca-issuer -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q "True"; then
                      echo "✓ ClusterIssuer 'lab-k8s-ca-issuer' is ready!"
                      break 2 # Break both loops
                    else
                      echo "ClusterIssuer 'lab-k8s-ca-issuer' not ready yet. Retrying in $issuer_retry_delay seconds..."
                    fi
                    sleep $issuer_retry_delay
                  done

                  echo "✗ ClusterIssuer 'lab-k8s-ca-issuer' was not ready after $((issuer_max_retries * issuer_retry_delay)) seconds."
                  exit 1
                else
                  echo "Failed to apply cert-manager, retrying in $cm_retry_delay seconds..."
                fi
                sleep $cm_retry_delay
              done

              if (( i > cm_max_retries )); then
                echo "✗ Failed to apply cert-manager after $((cm_max_retries * cm_retry_delay)) seconds."
                exit 1
              fi
              echo "✓ Cert Manager installed."
            }
          '';

          install-argocd-fn = ''
            install_argocd() {
              echo "--- Installing ArgoCD ---"
              kubectl apply -f manifests/infra/argocd
              kubectl rollout status -n argocd deployment argocd-server
              kubectl apply -f manifests/infra/bootstrap.yaml
              echo "✓ ArgoCD installed."
            }
          '';

          wait-for-kuma-fn = ''
            wait_for_kuma() {
              echo "--- Waiting for Kuma Control Plane ---"
              local namespace="kuma-system"
              local deployment="kuma-control-plane"
              local max_retries=10
              local retry_delay=30
              local i

              for ((i=1; i<=max_retries; i++)); do
                echo "Attempt $i: Checking if deployment \"$deployment\" exists in namespace \"$namespace\"..."
                if kubectl get deployment -n "$namespace" "$deployment" &>/dev/null; then
                  echo "Deployment found. Checking rollout status..."
                  if kubectl rollout status -n "$namespace" deployment "$deployment"; then
                    echo "✓ Kuma deployment is ready!"
                    return 0
                  fi
                else
                  echo "Deployment \"$deployment\" not found yet. Retrying in $retry_delay seconds..."
                fi
                sleep "$retry_delay"
              done

              echo "✗ Deployment $deployment in namespace $namespace was not ready after $((max_retries * retry_delay)) seconds."
              exit 1
            }
          '';

          apply-dev-bootstrap-fn = ''
            apply_dev_bootstrap() {
              echo "--- Applying dev bootstrap ---"
              kubectl apply -f manifests/dev/bootstrap.yaml
              echo "✓ Dev bootstrap applied."
            }
          '';

          shellcheckFunctionRegistry = [
            "build_yamls"
            "install_sops_operator"
            "install_cert_manager"
            "install_argocd"
            "wait_for_kuma"
            "apply_dev_bootstrap"
            "check_scripts"
          ];

          check-scripts-fn = ''
            check_scripts() {
              set -e
              echo "--- Running ShellCheck on script functions ---"

              # Create a temporary file for checking.
              check_file=$(mktemp)
              # Set a trap to ensure the temp file is cleaned up on exit.
              trap 'rm -f "$check_file"' EXIT

              # The list of functions to check is generated by Nix.
              local functions_to_check=(
                ${builtins.concatStringsSep " " shellcheckFunctionRegistry}
              )

              for name in "''${functions_to_check[@]}"; do
                echo "Checking function: $name"
                # Use `declare -f` to get the function's body at runtime.
                local body
                body="$(declare -f "$name")"

                echo "#!${pkgs.bash}/bin/bash" > "$check_file"
                echo "$body" >> "$check_file"
                shellcheck "$check_file"
              done

              echo "✓ All checks passed."
            }
          '';

        in
        {
          build = {
            type = "app";
            program =
              let
                drv = pkgs.writeShellApplication {
                  name = "build-yamls";
                  runtimeInputs = [ self.packages.${system}.nixidy ];
                  text = ''
                    ${build-yamls-fn}
                    build_yamls "$@"
                  '';
                };
              in
              "${drv}/bin/build-yamls";
          };

          init = {
            type = "app";
            program =
              let
                drv = pkgs.writeShellApplication {
                  name = "init-cluster";
                  runtimeInputs = with pkgs; [ kubectl gnused gnugrep coreutils ];
                  text = ''
                    set -e
                    ${install-sops-operator-fn}
                    ${install-cert-manager-fn}
                    ${install-argocd-fn}
                    ${wait-for-kuma-fn}
                    ${apply-dev-bootstrap-fn}

                    main() {
                      install_sops_operator
                      install_cert_manager
                      install_argocd
                      wait_for_kuma
                      apply_dev_bootstrap
                      echo "🎉 Cluster initialization complete!"
                    }

                    main "$@"
                  '';
                };
              in
              "${drv}/bin/init-cluster";
          };

          check = {
            type = "app";
            program =
              let
                drv = pkgs.writeShellApplication {
                  name = "check-scripts";
                  runtimeInputs = with pkgs; [ shellcheck coreutils bash ]; # coreutils for mktemp
                  text = ''
                    # Define all functions in the script's scope so `declare -f` can find them.
                    ${build-yamls-fn}
                    ${install-sops-operator-fn}
                    ${install-cert-manager-fn}
                    ${install-argocd-fn}
                    ${wait-for-kuma-fn}
                    ${apply-dev-bootstrap-fn}
                    ${check-scripts-fn}

                    # Execute the main check function.
                    check_scripts "$@"
                  '';
                };
              in
              "${drv}/bin/check-scripts";
          };
        }
      );
    };
}
