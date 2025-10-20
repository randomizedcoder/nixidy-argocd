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
        system: pkgs: {
          build = {
            type = "app";
            program = toString (
              pkgs.writeScript "build-yamls" # bash
                ''
                  #!${pkgs.bash}/bin/bash
                  set -e

                  # Default to "all" if no argument provided
                  target_env="''${1:-all}"

                  # Available environments
                  available_envs="${builtins.concatStringsSep " " environments}"

                  if [ "$target_env" = "all" ]; then
                    # Build all environments
                    for env in $available_envs; do
                      echo "Generating App manifests for $env..."
                      ${self.packages.${system}.nixidy}/bin/nixidy switch .#$env
                      echo "Generating App of Apps for $env..."
                      ${self.packages.${system}.nixidy}/bin/nixidy bootstrap .#$env > manifests/$env/bootstrap.yaml
                    done
                  else
                    # Check if the specified environment exists
                    env_found=false
                    for env in $available_envs; do
                      if [ "$env" = "$target_env" ]; then
                        env_found=true
                        break
                      fi
                    done
                    
                    if [ "$env_found" = "true" ]; then
                      echo "Generating App manifests for $target_env..."
                      ${self.packages.${system}.nixidy}/bin/nixidy switch .#$target_env
                      echo "Generating App of Apps for $target_env..."
                      ${self.packages.${system}.nixidy}/bin/nixidy bootstrap .#$target_env > manifests/$target_env/bootstrap.yaml
                    else
                      echo "Error: Environment '$target_env' not found."
                      echo "Available environments: $available_envs"
                      exit 1
                    fi
                  fi
                ''
            );
          };

          init = {
            type = "app";
            program = toString (
              pkgs.writeScript "init-cluster" # bash
                ''
                  #!${pkgs.bash}/bin/bash
                  set -e
                  echo "Installing sops-secrets-operator on cluster"

                  # Create namespace and secret
                  ${pkgs.kubectl}/bin/kubectl apply -f - <<EOF
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
                    key.txt: $(base64 -w 0 < key.txt)
                  EOF

                  ${pkgs.kubectl}/bin/kubectl apply -f manifests/infra/sops-secrets-operator
                  ${pkgs.kubectl}/bin/kubectl rollout status -n sops-operator deployment sops-sops-secrets-operator

                  echo "Installing Cert Manager"
                  ${pkgs.kubectl}/bin/kubectl apply -f manifests/infra/k8s-gw-api-crds

                  cm_max_retries=5
                  cm_retry_delay=10
                  issuer_max_retries=3
                  issuer_retry_delay=5

                  for ((i=1; i<=cm_max_retries; i++)); do
                      echo "Attempt $i: Applying cert-manager manifests..."
                      if ${pkgs.kubectl}/bin/kubectl apply -f manifests/infra/cert-manager; then
                          echo "Cert-manager applied successfully. Checking ClusterIssuer 'lab-k8s-ca-issuer' readiness..."

                          for ((j=1; j<=issuer_max_retries; j++)); do
                              echo "Attempt $j: Checking if ClusterIssuer 'lab-k8s-ca-issuer' is ready..."
                              if ${pkgs.kubectl}/bin/kubectl get clusterissuer lab-k8s-ca-issuer -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q "True"; then
                                  echo "ClusterIssuer 'lab-k8s-ca-issuer' is ready!"
                                  break 2 # Break both loops
                              else
                                  echo "ClusterIssuer 'lab-k8s-ca-issuer' not ready yet. Retrying in $issuer_retry_delay seconds..."
                              fi
                              sleep $issuer_retry_delay
                          done

                          echo "ClusterIssuer 'lab-k8s-ca-issuer' was not ready after $((issuer_max_retries * issuer_retry_delay)) seconds."
                          exit 1
                      else
                          echo "Failed to apply cert-manager, retrying in $cm_retry_delay seconds..."
                      fi
                      sleep $cm_retry_delay
                  done

                  if (( i > cm_max_retries )); then
                      echo "Failed to apply cert-manager after $((cm_max_retries * cm_retry_delay)) seconds."
                      exit 1
                  fi

                  echo "Installing ArgoCD on cluster"
                  ${pkgs.kubectl}/bin/kubectl apply -f manifests/infra/argocd
                  ${pkgs.kubectl}/bin/kubectl rollout status -n argocd deployment argocd-server
                  ${pkgs.kubectl}/bin/kubectl apply -f manifests/infra/bootstrap.yaml

                  # Wait for ArgoCD to sync and the deployment to be ready
                  namespace="kuma-system"
                  deployment="kuma-control-plane"

                  # Define a maximum number of retries and a delay between retries
                  max_retries=10
                  retry_delay=30

                  # Retry loop
                  for ((i=1; i<=max_retries; i++)); do
                      echo "Attempt $i: Checking if deployment $deployment exists in namespace $namespace..."
                      if ${pkgs.kubectl}/bin/kubectl get deployment -n "$namespace" "$deployment" &>/dev/null; then
                          # Deployment exists, now check rollout status
                          echo "Deployment found. Checking rollout status..."
                          if ${pkgs.kubectl}/bin/kubectl rollout status -n "$namespace" deployment "$deployment"; then
                              echo "Deployment is ready!"
                              break
                          fi
                      else
                          echo "Deployment $deployment not found yet. Retrying in $retry_delay seconds..."
                      fi
                      sleep $retry_delay
                  done

                  # If the loop finishes without success
                  if (( i > max_retries )); then
                      echo "Deployment $deployment in namespace $namespace was not ready after $((max_retries * retry_delay)) seconds."
                      exit 1
                  fi
                  ${pkgs.kubectl}/bin/kubectl apply -f manifests/dev/bootstrap.yaml
                ''
            );
          };
        }
      );
    };
}
