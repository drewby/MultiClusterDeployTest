#!/bin/bash
#shellcheck disable=SC2317
# Set default values
: "${RESOURCE_GROUP:=argoCdDemo}"
: "${LOCATION:=eastus}"
: "${DEPLOYMENT_NAME:=argoCdDemo}"
: "${LINUX_ADMIN_USERNAME:=azureuser}"
: "${ENABLE_CONTROL_PLANE:=false}"
: "${CONTROL_PLANE_NAME:=controlPlane}"
: "${MANIFEST_URL:=https://raw.githubusercontent.com/drewby/argocd-manifests/main/jal/{clustername\}/nonprod/consumer/argocd/master-manifest.yaml}"
: "${SKIP_CONFIRMATION:=false}"
: "${ARGOCD_PASSWORD:=}"
: "${SSH_PUBLIC_KEY:=}"
: "${EXTERNAL_IP:=}"
: "${JSON_LOGS:=false}"
: "${TEST_RESULTS_DIR:=./test-results}"
: "${MODE:=k3d}"
: "${EDGE_CLUSTER_COUNT:=3}"
: "${EDGE_CLUSTER_NAMES:=}"
: "${TEMP_DIR:=$(mktemp -d)}"
: "${VERBOSE:=false}"

# Generate global run ID
RUN_ID=$(date +%s%N | md5sum | cut -c1-5)
EXIT_FLAG=0
TIMESTAMP=$(date +%Y%m%d%H%M%S)

# Display usage
usage() {
  echo "Multi-Cluster Deployment Tester"
  echo "Usage: $0 <command> [options]"
  echo "Commands:"
  echo "  all            Execute all steps: deployment of clusters (k3d or azure), Argo CD, manifests, and tests"
  echo "  k3d            Deploy k3d infrastructure"
  echo "  azure          Deploy Azure infrastructure"
  echo "  argocd         Deploy Argo CD"
  echo "  manifests      Apply manifests to edge clusters"
  echo "  test           Execute tests"
  echo "  delete         Delete k3d or azure infrastructure"
  echo ""
  echo "Options:"
  echo "  -m, --mode <value>               Set the mode to deploy clusters (default: k3d)"
  echo "  -n, --edge-cluster-count <value> Set the number of edge clusters to deploy (default: 3)"
  echo "  -c, --edge-cluster-names <value> Provide a comma-separated list of edge cluster names to deploy (default: cluster1,cluster2,cluster3, etc)"
  echo "  -r, --resource-group <value>     Set the Azure resource group (default: argoCdDemo)"
  echo "  -l, --location <value>           Set the Azure location (default: eastus)"
  echo "  -d, --deployment-name <value>    Set the name of the Azure deployment (default: argoCdDemo)"
  echo "  -a, --admin-username <value>     Set the Linux admin username (default: azureuser)"
  echo "  -e, --enable-control-plane       Enable a control plane cluster to deploy to edge clusters"
  echo "  -C, --control-plane-name <value> Set the name of the control plane cluster (default: controlPlane)"
  echo "  -u, --manifest-url <value>       Provide the URL to the edge cluster manifests"
  echo "                                   (required if the MANIFEST_URL environment variable is not set)"
  echo "  -p, --argocd-password <value>    Set the password for Argo CD (default: none)"
  echo "  -j, --json-logs                  Enable output of logs in JSON format"
  echo "  -o, --output <value>             Set the output directory for test results (default: ./test-results)"
  echo "  -y, --yes                        Enable skipping of the confirmation prompt"
  echo "  -v, --verbose                    Enable verbose output"
  echo "  -h, --help                       Display this usage information"
  echo ""
  echo "Environment variables:"
  echo "  MODE                             Set the mode to deploy clusters"
  echo "  EDGE_CLUSTER_COUNT               Set the number of edge clusters to deploy"
  echo "  EDGE_CLUSTER_NAMES               Set the names of edge clusters to deploy"
  echo "  RESOURCE_GROUP                   Set the Azure resource group"
  echo "  LOCATION                         Set the Azure location"
  echo "  DEPLOYMENT_NAME                  Set the name of the Azure deployment"
  echo "  LINUX_ADMIN_USERNAME             Set the Linux admin username"
  echo "  ENABLE_CONTROL_PLANE             Enable the control plane to deploy to edge clusters (set to 'true')"
  echo "  CONTROL_PLANE_NAME               Set the name of the control plane cluster"
  echo "  MANIFEST_URL                     Set the URL to the edge cluster manifests"
  echo "  ARGOCD_PASSWORD                  Set the password for Argo CD"
  echo "  SSH_PUBLIC_KEY                   Set the public SSH key"
  echo "  JSON_LOGS                        Enable output of logs in JSON format (set to 'true')"
  echo "  TEST_RESULTS_DIR                 Set the output directory for test results"
  echo ""
  echo "Note: The order of precedence is command line arguments, environment variables, and then defaults."
  echo "For more detailed information and examples, please refer to the documentation."
}


# Log to console
# Usage: log <level> <message> [data]
#  level: log level (info, warn, error)
#  message: log message
#  data: optional data in JSON format added if JSON_LOGS is true
log() {
  local level="$1"
  local message="$2"
  local timestamp
  timestamp=$(date +"%Y-%m-%d %H:%M:%S.%3N")
  local source="${3:-trun}"
  local data="${4:-[]}"

  if [ "$JSON_LOGS" = true ]; then
    jq -n -c \
      --arg timestamp "$timestamp" \
      --arg level "$level" \
      --arg runId "$RUN_ID" \
      --arg message "$message" \
      --arg source "$source" \
      --argjson data "$data" \
      '{timestamp: $timestamp, level: $level, runId: $runId, source: $source, message: $message, data: $data}'
    return 0
  fi

  logmessage="$timestamp $(printf "%-8s" "[$level]") [$RUN_ID] $(printf "%-10s" "[$source]") $message"
  if [ "$level" = "error" ]; then
    echo -e "\033[0;31m$logmessage\033[0m" >&2
  elif [ "$level" = "warn" ]; then
    echo -e "\033[0;33m$logmessage\033[0m" 
  else
    echo "$logmessage" 
  fi
}

redirect() {
  cmd="$1"

  if [[ -z "$cmd" ]]; then
    log "error" "Command is required."
    exit 1
  fi

  label=$(echo "$cmd" | awk '{print $1}')
  
  # remove color codes and INFO[0-9] from output
  cmd="$cmd | sed -u -r \"s/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[mGK]//g\" | sed -u -E 's/INFO\[[0-9]+\] //'; return \${PIPESTATUS[0]}"

  # Create named pipes for stdout and stderr
  # This allows us to wait for the processes to finish
  # Otherwise, log messages appear out of order
  local stdout_pipe; stdout_pipe=$(mktemp -u)
  local stderr_pipe; stderr_pipe=$(mktemp -u)
  mkfifo "$stdout_pipe" "$stderr_pipe"

  # Start the processes for stdout and stderr redirection

  # stdout
  {
    while read -r line; do
      if [[ "$VERBOSE" = true ]]; then
        log "info" "$line" "$label"
      fi
    done < "$stdout_pipe"
  } & local stdout_pid=$!

  # stderr
  {
    while read -r line; do
      log "error" "$line" "$label"
    done < "$stderr_pipe"
  } & local stderr_pid=$!

  # get exit code of command so we can return it
  eval "$cmd" > "$stdout_pipe" 2> "$stderr_pipe" 

  # Wait for stdout and stderr processes to finish
  # and then remove the named pipes
  wait "$stdout_pid" "$stderr_pid"
  rm "$stdout_pipe" "$stderr_pipe"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--mode)
      MODE="$2"
      shift 2
      ;;
    -n|--edge-cluster-count)
      EDGE_CLUSTER_COUNT="$2"
      shift 2
      ;;
    -c|--edge-cluster-names)
      EDGE_CLUSTER_NAMES="$2"
      shift 2
      ;;
    -r|--resource-group)
      RESOURCE_GROUP="$2"
      shift 2
      ;;
    -l|--location)
      LOCATION="$2"
      shift 2
      ;;
    -d|--deployment-name)
      DEPLOYMENT_NAME="$2"
      shift 2
      ;;
    -a|--admin-username)
      LINUX_ADMIN_USERNAME="$2"
      shift 2
      ;;
    -e|--enable-control-plane)
      ENABLE_CONTROL_PLANE=true
      shift
      ;;
    -C|--control-plane)
      CONTROL_PLANE_NAME="$2"
      shift 2
      ;;
    -u|--manifest-url)
      MANIFEST_URL="$2"
      shift 2
      ;;
    -p|--argocd-password)
      ARGOCD_PASSWORD="$2"
      shift 2
      ;;
    -y|--yes)
      SKIP_CONFIRMATION=true
      shift
      ;;
    -j|--json-logs)
      JSON_LOGS=true
      shift
      ;;
    -o|--output)
      TEST_RESULTS_DIR="$2"
      shift 2
      ;;
    -v|--verbose)
      VERBOSE=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    all|k3d|azure|argocd|manifests|delete|test)
      COMMAND="$1"
      shift
      ;;
    *)
      log "error" "Invalid argument: $1"
      usage
      exit 1
      ;;
  esac
done

# Validate command is set
if [[ -z "$COMMAND" ]]; then
  log "error" "Command is required."
  usage
  exit 1
fi

# Validate mode is either k3d or azure
if [[ "$MODE" != "k3d" && "$MODE" != "azure" ]]; then
  log "error" "Mode must be either k3d or azure."
  usage
  exit 1
fi

# If mode is azure, validate Azure CLI is installed
if [[ "$MODE" = "azure" ]]; then
  if ! az --version > /dev/null 2>&1; then
    log "error" "Azure CLI is not installed."
    exit 1
  fi
fi

# Login to Azure if not already logged in
login_to_azure() {
  if ! redirect "az account show"; then
    log "info" "Logging into Azure..."
    if az login --use-device-code --output none; then
      log "info" "Logged into Azure successfully."
    else
      log "error" "Failed to log into Azure."
      exit 1
    fi
  else 
    log "info" "Already logged into Azure."
  fi
}

# Generate SSH key if not already exists, return public key
generate_ssh_key() {
  if [[ -n "$SSH_PUBLIC_KEY" ]]; then
    return
  fi

  if [ ! -f ~/.ssh/id_rsa.pub ]; then
    log "info" "Generating SSH key..."
    if ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -q -N ""; then
      log "info" "SSH key generated successfully."
    else
      log "error" "Failed to generate SSH key."
      exit 1
    fi
  else
    log "info" "Found public SSH key."
  fi
  SSH_PUBLIC_KEY=$(cat ~/.ssh/id_rsa.pub)
}

# Create resource group, if not already exists
create_resource_group() {
  if [[ -z "$RESOURCE_GROUP" || -z "$LOCATION" ]]; then
    log "error" "Resource group name and location must not be empty."
    exit 1
  fi

  if redirect "az group show --name \"$RESOURCE_GROUP\" --output none"; then
    log "warn" "Resource group $RESOURCE_GROUP already exists."
    return
  fi

  log "info" "Creating resource group $RESOURCE_GROUP in $LOCATION..."
  if redirect "az group create --name \"$RESOURCE_GROUP\" --location \"$LOCATION\" --output none"; then
    log "info" "Resource group $RESOURCE_GROUP created successfully."
  else
    log "error" "Failed to create resource group $RESOURCE_GROUP."
    exit 1
  fi
}

# Deploy Azure infrastructure as defined in main.bicep
deploy_azure_infra() {
  if [[ -z "$RESOURCE_GROUP" || -z "$LINUX_ADMIN_USERNAME" || -z "$SSH_PUBLIC_KEY" || -z "$DEPLOYMENT_NAME" ]]; then
    log "error" "Resource group name, Linux admin username, SSH public key, and Deployment Name must not be empty."
    exit 1
  fi

  log "info" "Deploying Azure infrastructure..."

  # if EDGE_CLUSTER_NAMES is empty, generate a list of cluster names
  # based on EDGE_CLUSTER_COUNT using the format cluster1,cluster2,cluster3, etc
  if [[ -z "$EDGE_CLUSTER_NAMES" ]]; then
    EDGE_CLUSTER_NAMES=$(seq -s, -f 'cluster%g' "$EDGE_CLUSTER_COUNT")
  fi

  if az deployment group create \
        --resource-group "$RESOURCE_GROUP" \
        --name "$DEPLOYMENT_NAME" \
        --template-file azure/main.bicep \
        --parameters linuxAdminUsername="$LINUX_ADMIN_USERNAME" \
        sshRSAPublicKey="$SSH_PUBLIC_KEY" \
        edgeClusterNames="$EDGE_CLUSTER_NAMES" \
        enableControlPlane="$ENABLE_CONTROL_PLANE" \
        --output none; then
    log "info" "Bicep template deployment succeeded."
  else
    log "error" "Bicep template deployment failed."
    exit 1
  fi

  log "info" "Azure infrastructure deployment complete."
}

# Get cluster credentials and set kubectl context
# 1. Get list of cluster names from Azure CLI
# 2. Get credentials for each cluster using az aks get-credentials
get_azure_kube_credentials() {
  if [[ -z "$RESOURCE_GROUP" || -z "$CONTROL_PLANE_NAME" ]]; then
    log "error" "Resource group name and control plane name must not be empty."
    exit 1
  fi

  log "info" "Retrieving credentials for all clusters..."

  # Get list of cluster names (don't filter out CONTROL_PLANE_NAME)
  clusters=$(az aks list --resource-group "$RESOURCE_GROUP" --query "[].name" -o tsv)

  # Get credentials for each cluster
  for cluster in $clusters; do
    if redirect "az aks get-credentials --resource-group \"$RESOURCE_GROUP\" --name \"$cluster\" --overwrite-existing"; then
      log "info" "Credentials retrieved successfully for cluster $cluster."
    else
      log "error" "Failed to retrieve credentials for cluster $cluster."
    fi
  done

  log "info" "Credential retrieval for all clusters complete."
}

# Deploy k3d clusters
# 1. Check k3d is installed
# 2. Check CONTROL_PLANE_NAME is not empty
# 3. Create docker network edgeClusters if it does not exist. We create this network with
#    docker instead of k3d so we can control the configuration of the network.
# 4. Create k3d CONTROL_PLANE_NAME cluster
# 5. Create k3d EDGE_CLUSTER_COUNT edge clusters
deploy_k3d_clusters() {
  local k3dnetwork="edgeClusters"

  # check k3d is installed
  if ! command -v k3d > /dev/null; then
    log "error" "k3d is not installed."
    log "info" "If you'd like to use Azure, use --mode azure or set the MODE environment variable to azure."
    exit 1
  fi

  # check if ENABLE_CONTROL_PLANE is true and the CONTROL_PLANE_NAME is not empty
  if [[ "$ENABLE_CONTROL_PLANE" = true && -z "$CONTROL_PLANE_NAME" ]]; then
    log "error" "CONTROL_PLANE_NAME must not be empty."
    exit 1
  fi

  # if docker network $k3dnetwork does not exist, create it
  if ! redirect "docker network inspect \"$k3dnetwork\""; then
    log "info" "Creating docker network $k3dnetwork..."
    if redirect "docker network create \"$k3dnetwork\" --driver bridge --ip-range 172.28.0.0/16 --subnet 172.28.0.0/16 --gateway 172.28.0.1"; then
      log "info" "Docker network $k3dnetwork created successfully."
    else
      log "error" "Failed to create docker network $k3dnetwork."
      exit 1
    fi
  else
    log "info" "Docker network $k3dnetwork already exists."
  fi

  # if ENABLE_CONTROL_PLANE is true
  if [[ "$ENABLE_CONTROL_PLANE" = true ]]; then
    # check if the CONTROL_PLANE_NAME cluster exists
    if k3d cluster list | grep -q "$CONTROL_PLANE_NAME"; then
      log "info" "k3d cluster $CONTROL_PLANE_NAME already exists."
    else
      log "info" "Creating k3d cluster $CONTROL_PLANE_NAME..."
      if redirect "k3d cluster create \"$CONTROL_PLANE_NAME\" --no-lb --k3s-arg --disable=traefik@server:0 --network \"$k3dnetwork\""; then
        log "info" "k3d cluster $CONTROL_PLANE_NAME created successfully."
      else
        log "error" "Failed to create k3d cluster $CONTROL_PLANE_NAME."
        exit 1
      fi
    fi
  fi 

  # if EDGE_CLUSTER_NAMES is empty, generate a list of cluster names
  # based on EDGE_CLUSTER_COUNT using the format cluster1,cluster2,cluster3, etc
  if [[ -z "$EDGE_CLUSTER_NAMES" ]]; then
    EDGE_CLUSTER_NAMES=$(seq -s, -f 'cluster%g' "$EDGE_CLUSTER_COUNT")
  fi
  
  # Prefer mapfile or read -a to split command output (or quote to avoid splitting).
 
  IFS="," read -ra edgeclusters <<< "$EDGE_CLUSTER_NAMES"
  # for each cluster name in EDGE_CLUSTER_NAMES, create the cluster
  for cluster in "${edgeclusters[@]}"; do
    #check if the cluster exists
    if k3d cluster list | grep -q "$cluster"; then
      log "info" "k3d cluster $cluster already exists."
    else
      log "info" "Creating k3d cluster $cluster..."
      if redirect "k3d cluster create \"$cluster\" --no-lb --k3s-arg --disable=traefik@server:0 --network \"$k3dnetwork\""; then
        log "info" "k3d cluster $cluster created successfully."
      else
        log "error" "Failed to create k3d cluster $cluster."
        exit 1
      fi
    fi
  done <<< "$EDGE_CLUSTER_NAMES"

  log "info" "k3d cluster creation complete."
}

# Modify kubeconfig contexts to remove k3d- prefix and fix server addresses
modify_k3d_kube_credentials() {

  # get the list of clusters and IP addresses from k3d
  clusters=$(k3d cluster list -o json | jq '[.[] | {name: .name, ip: (.nodes[] | select(.role=="server") | .IP.IP) }]')

  # get the list of kubeconfig contexts from kubectl and rename
  # to remove k3d- prefix 
  log "info" "Renaming kubeconfig contexts and fixing server addresses..."
  contexts=$(kubectl config get-contexts -o name)
  for context in $contexts; do
    if [[ "$context" == k3d-* ]]; then
      new_context="${context//k3d-/}"
      # if the new context already exists, delete it
      if kubectl config get-contexts -o name | grep -q "^$new_context$"; then
        kubectl config delete-context "$new_context" > /dev/null
      fi

      kubectl config rename-context "$context" "$new_context" > /dev/null

      # get the IP address from the k3d cluster list and set 
      # the server address in the kubeconfig to https://<ip>:6443
      ip=$(echo "$clusters" | jq -r --arg context "$new_context" '.[] | select(.name==$context) | .ip')
      kubectl config set-cluster "$context" --server="https://$ip:6443" > /dev/null
    fi
  done

  log "info" "kubeconfig contexts renamed and server addresses fixed."
}

# Set kubectl context
# Usage: set_kubectl_context <context>
set_kubectl_context() {
  local context="$1"

  if [[ -z "$context" ]]; then
    log "error" "Context name must not be empty."
    exit 1
  fi

  log "info" "Setting kubectl context to $context..."

  if kubectl config use-context "$context" > /dev/null; then
    log "info" "kubectl context set to $context."
  else
    log "error" "Failed to set kubectl context to $context."
    exit 1
  fi
}

# Deploy Argo CD to a cluster
# Usage: deploy_argocd <cluster_name>
# 1. Set kubectl context to <cluster_name>
# 2. Check if argocd namespace already exists
# 3. Remove ~/.config/argocd directory if it exists
# 4. Create argocd namespace
# 5. Apply Argo CD manifests
# 6. Wait for argocd-server deployment to be ready
# 7. Patch argocd-server service to use LoadBalancer
deploy_argocd() {
  cluster=$1

  # if $cluster is empty, set to CONTROL_PLANE_NAME. If CONTROL_PLANE_NAME is empty, exit.
  if [[ -z "$cluster" ]]; then
    if [[ -n "$CONTROL_PLANE_NAME" ]]; then
      cluster="$CONTROL_PLANE_NAME"
    else
      log "error" "Cluster name must not be empty."
      exit 1
    fi
  fi

  log "info" "Deploying Argo CD to cluster $cluster..."

  # Set kubectl context to the cluster
  set_kubectl_context "$cluster"

  # Check if argocd namespace already exists
  if kubectl get namespace argocd; then
    log "info" "Argo CD namespace already exists for $cluster. Skip deployment."
    return 0
  fi

  # Create argocd namespace
  if ! redirect "kubectl create namespace argocd"; then
    log "error" "Failed to create argocd namespace in $cluster."
    exit 1
  fi

  # Apply Argo CD manifests
  if redirect "kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"; then
    log "info" "Argo CD manifests applied successfully for $cluster."
  else
    log "error" "Failed to apply Argo CD manifests in $cluster."
    exit 1
  fi

  # Wait for argocd-server deployment to be ready
  if redirect "kubectl wait deployment argocd-server -n argocd --for condition=available --timeout=90s"; then
    log "info" "argocd-server deployment is ready in $cluster."
  else
    log "error" "argocd-server deployment is not ready in $cluster."
    exit 1
  fi

  # Patch argocd-server service to use LoadBalancer
  if redirect "kubectl patch svc argocd-server -n argocd -p '{\"spec\": {\"type\": \"LoadBalancer\"}}'"; then
    log "info" "$cluster: argocd-server service patched to use LoadBalancer."
  else
    log "error" "Failed to patch argocd-server service in $cluster."
    exit 1
  fi

  log "info" "Argo CD installation completed for cluster $cluster."
}

# Deploy Argo CD to each edge cluster
# Usage: deploy_argocd_edgeclusters
# 1. Get a list of edge clusters
# 2. Loop through each cluster and deploy Argo CD using deploy_argocd function
deploy_argocd_edgeclusters() {
  # Get a list of edge clusters
  edgeClusters=$(kubectl config get-contexts -o name | grep -v "$CONTROL_PLANE_NAME")

  for cluster in $edgeClusters; do
    deploy_argocd "$cluster"
  done
}

# Get Argo CD external IP address
# 1. Wait for argocd-server service to have an external IP address
# 2. Get the external IP address
# 3. Set EXTERNAL_IP variable
get_external_ip() {
  cluster=$1

  # if $cluster is empty, set to CONTROL_PLANE_NAME. If CONTROL_PLANE_NAME is empty, exit.
  if [[ -z "$cluster" ]]; then
    if [[ -n "$CONTROL_PLANE_NAME" ]]; then
      cluster="$CONTROL_PLANE_NAME"
    else
      log "error" "Cluster name must not be empty."
      exit 1
    fi
  fi
  
  # Wait for argocd-server service to have an external IP address
  log "info" "Waiting for an external IP address for $cluster..."
  
  EXTERNAL_IP=""
  timeout=$(($(date +%s) + 60))
  until [[ $(date +%s) -gt $timeout ]]; do
    EXTERNAL_IP=$(kubectl get svc argocd-server -n argocd --output jsonpath='{.status.loadBalancer.ingress[0].ip}')
    if [ -n "$EXTERNAL_IP" ]; then
      break
    fi
    sleep 0.5
  done

  if [ -z "$EXTERNAL_IP" ]; then
    log "error" "Timeout waiting for argocd-server service to have an external IP address."
    exit 1
  fi  
  
  log "info" "External IP address for $cluster: $EXTERNAL_IP"
}

# Login to Argo CD, if not already logged in
# If ARGOCD_PASSWORD is not empty, update password
# 1. Check if argocd is already logged in
# 2. Wait for argocd-initial-admin-secret to be available
# 3. Get plain text password from argocd-initial-admin-secret secret
# 4. Login to Argo CD
# 5. If ARGOCD_PASSWORD is not empty, update password
login_to_argocd() {
  cluster=$1

  # if $cluster is empty, set to CONTROL_PLANE_NAME. If CONTROL_PLANE_NAME is empty, exit.
  if [[ -z "$cluster" ]]; then
    if [[ -n "$CONTROL_PLANE_NAME" ]]; then
      cluster="$CONTROL_PLANE_NAME"
    else
      log "error" "Cluster name must not be empty."
      exit 1
    fi
  fi

  # set context to $cluster
  set_kubectl_context "$cluster"
  get_external_ip "$cluster"

  # Check if argocd is already logged in
  if redirect "argocd account get --server \"$EXTERNAL_IP\""; then
    log "info" "Already logged in to Argo CD."
    return 0
  fi

  log "info" "Logging in to Argo CD..."

  # Wait for argocd-initial-admin-secret to be available
  if ! redirect "kubectl wait secret --namespace argocd argocd-initial-admin-secret --for=jsonpath='{.type}'=Opaque --timeout=90s"; then
    log "error" "Failed to get argocd-initial-admin-secret."
    exit 1
  fi

  # Get plain text password from argocd-initial-admin-secret secret
  adminSecret=$(kubectl get secret argocd-initial-admin-secret --namespace argocd --output jsonpath='{.data.password}' | base64 --decode)
  if [ -z "$adminSecret" ]; then
    log "error" "Failed to get admin password."
    exit 1
  fi

  # Log in to argocd with admin password
  if ! redirect "argocd login \"$EXTERNAL_IP\" --username admin --password \"$adminSecret\" --insecure"; then
    log "error" "Failed to log in to Argo CD."
    exit 1
  fi

  if [ -n "$ARGOCD_PASSWORD" ]; then
    # Update admin password
    if ! redirect "argocd account update-password --current-password \"$adminSecret\" --new-password \"$ARGOCD_PASSWORD\""; then
      log "error" "Failed to update admin password."
      exit 1
    fi
  fi

  log "info" "Logged in to Argo CD successfully."
}

# Login to ArgoCD on edge clusters
login_to_argocd_edgeclusters() {
  # Get a list of edge clusters
  edgeClusters=$(kubectl config get-contexts -o name | grep -v "$CONTROL_PLANE_NAME")

  for cluster in $edgeClusters; do
    login_to_argocd "$cluster"
  done
}


# Add edge clusters to Argo CD
# 1. Get edge clusters by querying kubeconfig contexts, ignore $CONTROL_PLANE_NAME
# 2. For each edge cluster, add it to Argo CD
add_argocd_clusters() {
  local edgeClusters
  
  log "info" "Adding edge clusters to Argo CD..."

  # get edgeClusters by querying kubeconfig contexts, ignore $CONTROL_PLANE_NAME
  edgeClusters=$(kubectl config get-contexts -o name | grep -v "$CONTROL_PLANE_NAME")

  for cluster in $edgeClusters; do
    if redirect "argocd cluster add \"$cluster\" -y"; then
      log "info" "Added $cluster to Argo CD successfully."
    else
      log "error" "Failed to add $cluster to Argo CD."
    fi
  done
}

# Deploy Argo CD applications
# For each edge cluster, apply manifests from manifestUrl template
# The template must contain {clustername} placeholder
# 1. Get edge clusters by querying kubeconfig contexts, ignore $CONTROL_PLANE_NAME
# 2. For each edge cluster, apply manifests from manifestUrl template
#
# It would be better if we could use the kuttl test framework to apply manifests
# to the edge clusters. However, kuttl does not support applying manifests to
# multiple clusters at the same time. So, we have to use kubectl directly and
# set the context for each cluster.
apply_manifests() {
  local edgeClusters

  # Require resourceGroup, controlPlane, manifestUrl
  if [[ -z "$RESOURCE_GROUP" || -z "$MANIFEST_URL" ]]; then
    log "error" "Resource group name, and Manifest URL template must not be empty."
    exit 1
  fi

  # if ENABLE_CONTROL_PLANE is true, CONTROL_PLANE_NAME must not be empty
  if [[ "$ENABLE_CONTROL_PLANE" = true && -z "$CONTROL_PLANE_NAME" ]]; then
    log "error" "CONTROL_PLANE_NAME must not be empty."
    exit 1
  fi

  # if ENABLE_CONTROL_PLANE is true, set context to CONTROL_PLANE_NAME
  if [[ "$ENABLE_CONTROL_PLANE" = true ]]; then
    set_kubectl_context "$CONTROL_PLANE_NAME"
  fi

  # Get list of edge clusters
  edgeClusters=$(kubectl config get-contexts -o name | grep -v "$CONTROL_PLANE_NAME")

  # Loop over each cluster and apply manifests
  for cluster in $edgeClusters; do
    if [[ "$ENABLE_CONTROL_PLANE" = false ]]; then
      set_kubectl_context "$cluster"
    fi

    local url="${MANIFEST_URL/\{clustername\}/$cluster}"
    if redirect "kubectl apply -f \"$url\""; then
      log "info" "Applied manifests for $cluster successfully."
    else
      log "error" "Failed to apply manifests for $cluster."
    fi
  done
}

# Run KUTTL tests, collect results
# 1. Get edge clusters by querying kubeconfig contexts, ignore $CONTROL_PLANE_NAME
# 2. For each edge cluster, run KUTTL tests in tests/{cluster} folder
# 3. Collect test results in a temporary folder
# 4. Aggregate test results into a single file in JUnit format
test_deployment() {
  local edgeClusters

  # Require resourceGroup, controlPlane
  if [[ -z "$RESOURCE_GROUP" || -z "$CONTROL_PLANE_NAME" ]]; then
    log "error" "Resource group name and control plane name must not be empty."
    exit 1
  fi

  # log info message
  log "info" "Running tests..."

  # Get list of edge clusters
  edgeClusters=$(kubectl config get-contexts -o name | grep -v "$CONTROL_PLANE_NAME")

  # Loop over each cluster and run tests
  for cluster in $edgeClusters; do
    set_kubectl_context "$cluster"

    local testFolder="tests/$cluster"
    local reportName="$cluster-$TIMESTAMP"
    if redirect "kubectl kuttl test --report JSON --artifacts-dir \"$TEMP_DIR\" --report-name \"$reportName\" \"$testFolder\""; then
      log "info" "Tests for $cluster completed."
    else
      log "error" "Tests for $cluster failed."
      EXIT_FLAG=1
    fi
  done
}

# Aggregate test results into a single file in JUnit format
# 1. Get edge clusters by querying kubeconfig contexts, ignore $CONTROL_PLANE_NAME
# 2. For each edge cluster, get test results in JSON format
# 3. Aggregate test results into a single file in JUnit format
# TODO: The schema here is wrong, needs to be updated.
aggregate_test_results() {
  local total=0 failures=0 errors=0 totalTime=0 totalTestSuites=()
  local testResultsName="results-$TIMESTAMP" 
  local testResultsFile="$TEST_RESULTS_DIR/$testResultsName.xml" 
  
  mkdir -p "$TEST_RESULTS_DIR"
  
  edgeClusters=$(kubectl config get-contexts -o name | grep -v "$CONTROL_PLANE_NAME")

  for cluster in $edgeClusters; do
    local reportName; reportName="$cluster-$TIMESTAMP" 
    local clusterResultsFile; clusterResultsFile="$TEMP_DIR/$reportName.json"

    log "info" "Parsing test results in $clusterResultsFile"
    
    # check if the file exists and has a .testsuite[] property
    if ! redirect "jq -e '.testsuite[]' \"$clusterResultsFile\""; then
      log "error" "Failed to parse test results in $clusterResultsFile"
      continue
    fi

    local testResults; testResults=$(jq -r '.testsuite[] | @base64' "$clusterResultsFile")

    for result in $testResults; do
      local testSuite; testSuite=$(base64 -d <<<"$result") testSuiteName=$(jq -r '.name' <<<"$testSuite")
      log "info" "Parsing test suite $testSuiteName"
      local testSuiteTests; testSuiteTests=$(jq -r '.tests' <<<"$testSuite") testSuiteFailures=0 testSuiteErrors=0
      local testSuiteTime; testSuiteTime=$(jq -r '.time' <<<"$testSuite") 
      local testSuiteTestCases; testSuiteTestCases=$(jq -r '.testcase[] | @base64' <<<"$testSuite") testCases=()

      for item in $testSuiteTestCases; do
        local testCase; testCase=$(base64 -d <<<"$item") 
        local testCaseClassName; testCaseClassName=$(jq -r '.classname' <<<"$testCase")
        local testCaseName; testCaseName=$testCaseClassName-$(jq -r '.name' <<<"$testCase")

        log "info" "Parsing test case $testCaseName"

        local testCaseTime; testCaseTime=$(jq -r '.time' <<<"$testCase") 
        local testCaseFailure; testCaseFailure=$(jq -r '.failure' <<<"$testCase")

        if [ "$testCaseFailure" != "null" ]; then
          local testCaseFailureMessage; testCaseFailureMessage=$(jq -r '.message' <<<"$testCaseFailure")
          local testCaseFailureText; testCaseFailureText=$(jq -r '.text' <<<"$testCaseFailure")
          testCases+=("<testcase name=\"$testCaseName\" time=\"$testCaseTime\">
            <failure message=\"$testCaseFailureMessage\">
              $testCaseFailureText
            </failure>
          </testcase>")

          log "error" "Test case $testCaseName failed: $testCaseFailureMessage: $testCaseFailureText"

          failures=$((failures + 1)) 
          testSuiteFailures=$((testSuiteFailures + 1))
        else
          testCases+=("<testcase name=\"$testCaseName\" time=\"$testCaseTime\" />")

          log "info" "Test case $testCaseName passed"
        fi

        total=$((total + 1)) totalTime=$(awk "BEGIN {print $totalTime + $testCaseTime; exit}")
      done

      totalTestSuites+=("<testsuite  name=\"$testSuiteName\" tests=\"$testSuiteTests\" errors=\"$testSuiteErrors\" failures=\"$testSuiteFailures\" skipped=\"0\" time=\"$testSuiteTime\">
      <properties>
        <property name=\"RunId\" value=\"$RUN_ID\" />
      </properties>
      $(printf '%s\n' "${testCases[@]}")
      </testsuite>")

      log "info" "Test suite $testSuiteName total tests: $testSuiteTests, failures: $testSuiteFailures, errors: $testSuiteErrors, time: $testSuiteTime"

    done # end of test suite loop
  done # end of cluster loop

  # create the test-results xml and save to file
  local testresults
  testresults="<testsuites>
  $(printf '%s\n' "${totalTestSuites[@]}")
  </testsuites>"

  if command -v xmllint >/dev/null 2>&1; then
    testresults=$(xmllint --format - <<<"$testresults")
  fi
  
  echo "$testresults" >"$testResultsFile"

  # log total tests, failures, errors, time
  log "info" "Total tests: $total, failures: $failures, errors: $errors, time: $totalTime"
  log "info" "Results saved to $testResultsFile"
}

# Delete the Azure resource group
delete_azure_resource_group() {
  if redirect "az group exists --name \"$RESOURCE_GROUP\""; then
    log "info" "Deleting resource group $RESOURCE_GROUP..."
    if redirect "az group delete --name \"$RESOURCE_GROUP\" --yes"; then
      log "info" "Deleted resource group $RESOURCE_GROUP successfully."
    else
      log "error" "Failed to delete resource group $RESOURCE_GROUP."
      exit 1
    fi
  fi
}

# Delete the k3d clusters
delete_k3d_clusters() {
  if k3d cluster list > /dev/null 2>&1; then
    # to output k3d logs without color codes, we use sed to remove the color codes
    # and remove the INFO[####] prefix
    if redirect "k3d cluster delete -a"; then
      log "info" "Deleted k3d clusters successfully."
    else
      log "error" "Failed to delete k3d clusters."
      exit 1
    fi
  fi
}

# Delete the local kubeconfig file
delete_kubeconfig() {
  if [ -f ~/.kube/config ]; then
    log "info" "Removing existing kubeconfig file..."
    rm ~/.kube/config
  fi
}

# Delete the argocd config directory
delete_argocd() {
  if [ -d ~/.config/argocd ]; then
    log "info" "Removing existing Argo CD configuration directory..."
    rm -rf ~/.config/argocd
  fi
}

declare -A timings
timeit() {
    local name="$1"
    local start
    local end
    start=$(date +%s.%N)
    "$@" 
    end=$(date +%s.%N)
    elapsed_time=$(awk "BEGIN {printf \"%.2f\", $end - $start}")
    timings["$name"]=$elapsed_time
}

declare -a steps
command_azure() {
  steps+=("login_to_azure")
  steps+=("generate_ssh_key")
  steps+=("create_resource_group")
  steps+=("deploy_azure_infra")
  steps+=("get_azure_kube_credentials")
}

command_k3d() {
  steps+=("deploy_k3d_clusters")
  steps+=("modify_k3d_kube_credentials")
}

command_argocd() {
  # if $ENABLE_CONTROL_PLANE is true, deploy Argo CD to the control plane
  # else deploy Argo CD to each edge cluster
  if [[ "$ENABLE_CONTROL_PLANE" = true ]]; then
    steps+=("deploy_argocd")
    steps+=("login_to_argocd")
    steps+=("add_argocd_clusters")
  else
    steps+=("deploy_argocd_edgeclusters")
    steps+=("login_to_argocd_edgeclusters")
  fi
}

command_manifests() {
  steps+=("apply_manifests")
}

command_delete() {
  if $SKIP_CONFIRMATION; then
    log "info" "Skipping confirmation..."
  else
    read -p "Are you sure you want to delete resource group $RESOURCE_GROUP? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      log "info" "Exiting..."
      exit 0
    fi
  fi
  if [ "$MODE" == "azure" ]; then
    steps+=("delete_azure_resource_group")
  else
    steps+=("delete_k3d_clusters")
  fi
  steps+=("delete_kubeconfig")
  steps+=("delete_argocd")
}

command_test() {
  steps+=("test_deployment")
  steps+=("aggregate_test_results")
}

command_all() {
  # if $MODE is azure, execute azure steps
  # else execute k3d steps
  if [ "$MODE" == "azure" ]; then
    command_azure
  else
    command_k3d
  fi
  command_argocd
  command_manifests
  command_test
}

# Execute command
case "$COMMAND" in
  azure)
    command_azure
    ;;
  k3d)
    command_k3d
    ;;
  argocd)
    command_argocd
    ;;
  manifests)
    command_manifests
    ;;
  test)
    command_test
    ;;
  delete)
    command_delete
    ;;
  all)
    command_all
    ;;
  *)
    log "error" "Invalid command: $COMMAND"
    exit 1
    ;;
esac

# Execute steps
for step in "${steps[@]}"; do
  timeit "$step"
done

# if $JSON_LOGS is true, log timings as json
if $JSON_LOGS; then
  json="{"
  for name in "${steps[@]}"; do
    json+="\"$name\": ${timings[$name]},"
  done
  json=${json%,}
  json+="}"
  log "info" "Step timings (s)" "trun" "$json"
  exit $EXIT_FLAG
fi

echo ""
printf "%-30s %s\n" "Step" "Duration (s)"
printf "%-30s %s\n" "---------------------" "---------------------"

for name in "${steps[@]}"; do
    printf "%-30s %s\n" "$name" "${timings[$name]}"
done
exit $EXIT_FLAG