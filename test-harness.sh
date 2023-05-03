#!/bin/bash
#shellcheck disable=SC2317
# Set default values
: "${RESOURCE_GROUP:=argoCdDemo}"
: "${LOCATION:=eastus}"
: "${DEPLOYMENT_NAME:=argoCdDemo}"
: "${LINUX_ADMIN_USERNAME:=azureuser}"
: "${CONTROL_PLANE:=controlPlane}"
: "${MANIFEST_URL:=https://raw.githubusercontent.com/drewby/argocd-manifests/main/jal/{clustername\}/nonprod/consumer/argocd/master-manifest.yaml}"
: "${SKIP_CONFIRMATION:=false}"
: "${ARGOCD_PASSWORD:=}"
: "${SSH_PUBLIC_KEY:=}"
: "${EXTERNAL_IP:=}"
: "${JSON_LOGS:=false}"
: "${TEST_RESULTS_DIR:=./test-results}"
: "${MODE:=k3d}"
: "${EDGE_CLUSTER_COUNT:=3}"
: "${TEMP_DIR:=$(mktemp -d)}"

# Generate global run ID
RUN_ID=$(date +%s%N | md5sum | cut -c1-5)
EXIT_FLAG=0
TIMESTAMP=$(date +%Y%m%d%H%M%S)

# Display usage
usage() {
  echo "Multi-Cluster Deployment Tester"
  echo "Usage: $0 <command> [options]"
  echo "Commands:"
  echo "  all            Deploy clusters (k3d or azure), Argo CD, manifests, and run tests"
  echo "  k3d            Deploy k3d infrastructure"
  echo "  azure          Deploy Azure infrastructure"
  echo "  argocd         Deploy Argo CD and edge clusters"
  echo "  manifests      Apply edge cluster manifests"
  echo "  test           Run tests"
  echo "  delete         Delete Azure infrastructure"
  echo ""
  echo "Options:"
  echo "  -m, --mode <value>               Mode to deploy clusters, can be k3d or azure (default: k3d)"
  echo "  -n, --edge-cluster-count <value> Number of edge clusters to deploy (default: 3)"
  echo "  -r, --resource-group <value>     Azure resource group (default: argoCdDemo)"
  echo "  -l, --location <value>           Azure location (default: eastus)"
  echo "  -d, --deployment-name <value>    Name of Azure deployment (default: argoCdDemo)"
  echo "  -a, --admin-username <value>     Linux admin username (default: azureuser)"
  echo "  -c, --control-plane <value>      Name of control plane cluster (default: controlPlane)"
  echo "  -u, --manifest-url <value>       URL to edge cluster manifests"
  echo "                                   (required if MANIFEST_URL environment variable not set)"
  echo "  -p, --argocd-password <value>    Password for Argo CD (default: none)"
  echo "  -j, --json-logs                  Output logs in JSON format"
  echo "  -o, --output <value>             Output directory for test results (default: ./test-results)"
  echo "  -y, --yes                        Skip confirmation prompt"
  echo "  -h, --help                       Display usage"
  echo ""
  echo "Environment variables:"
  echo "  MODE                             Mode to deploy clusters, can be k3d or azure"
  echo "  EDGE_CLUSTER_COUNT               Number of edge clusters to deploy"
  echo "  RESOURCE_GROUP                   Azure resource group"
  echo "  LOCATION                         Azure location"
  echo "  DEPLOYMENT_NAME                  Name of Azure deployment"
  echo "  LINUX_ADMIN_USERNAME             Linux admin username"
  echo "  CONTROL_PLANE                    Name of control plane cluster"
  echo "  MANIFEST_URL                     URL to edge cluster manifests"
  echo "  ARGOCD_PASSWORD                  Password for Argo CD"
  echo "  SSH_PUBLIC_KEY                   Public SSH key"
  echo "  JSON_LOGS                        Output logs in JSON format"
  echo "  TEST_RESULTS_DIR                 Output directory for test results"
  echo ""
  echo "The order of precedence is command line arguments, environment variables, and then defaults."
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
  local data="${3:-[]}"

  if [ "$JSON_LOGS" = true ]; then
    jq -n -c \
      --arg timestamp "$timestamp" \
      --arg level "$level" \
      --arg runId "$RUN_ID" \
      --arg message "$message" \
      --argjson data "$data" \
      '{timestamp: $timestamp, level: $level, runId: $RUN_ID, message: $message, data: $data}'
    return 0
  fi

  if [ "$level" = "error" ]; then
    echo -e "\033[0;31m$timestamp $(printf "%-8s" "[$level]") [$RUN_ID] $message\033[0m"
  elif [ "$level" = "warn" ]; then
    echo -e "\033[0;33m$timestamp $(printf "%-8s" "[$level]") [$RUN_ID] $message\033[0m" 
  else
    echo "$timestamp $(printf "%-8s" "[$level]") [$RUN_ID] $message"
  fi
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
    -c|--control-plane)
      CONTROL_PLANE="$2"
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
  if ! az account show > /dev/null 2>&1; then
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

  if az group show --name "$RESOURCE_GROUP" --output none > /dev/null 2>&1; then
    log "warn" "Resource group $RESOURCE_GROUP already exists."
    return
  fi

  log "info" "Creating resource group $RESOURCE_GROUP in $LOCATION..."
  if az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none; then
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

  if az deployment group create --resource-group "$RESOURCE_GROUP" --name "$DEPLOYMENT_NAME" --template-file azure/main.bicep --parameters linuxAdminUsername="$LINUX_ADMIN_USERNAME" sshRSAPublicKey="$SSH_PUBLIC_KEY" edgeClusterCount="$EDGE_CLUSTER_COUNT" --output none; then
    log "info" "Bicep template deployment succeeded."
  else
    log "error" "Bicep template deployment failed."
    exit 1
  fi

  log "info" "Azure infrastructure deployment complete."
}

# Display control plane values from Bicep template output
display_azure_control_plane_values() {
  if [[ -z "$RESOURCE_GROUP" || -z "$DEPLOYMENT_NAME" ]]; then
    log "error" "Resource group name and Deployment name must not be empty."
    exit 1
  fi

  log "info" "Retrieving control plane values..."

  # Get control plane values from Bicep template output
  controlPlaneName=$(az deployment group show --resource-group "$RESOURCE_GROUP" --name "$DEPLOYMENT_NAME" --query properties.outputs.controlPlaneName.value -o tsv)
  controlPlaneFQDN=$(az deployment group show --resource-group "$RESOURCE_GROUP" --name "$DEPLOYMENT_NAME" --query properties.outputs.controlPlaneFQDN.value -o tsv)

  if [[ -z "$controlPlaneName" || -z "$controlPlaneFQDN" ]]; then
    log "error" "Failed to retrieve control plane values."
    exit 1
  fi

  if $JSON_LOGS; then
    log "info" "Control plane values" "{\"controlPlaneName\": \"$controlPlaneName\", \"controlPlaneFQDN\": \"$controlPlaneFQDN\"}"
  else
    log "info" "controlPlaneName: $controlPlaneName"
    log "info" "controlPlaneFQDN: $controlPlaneFQDN"
  fi
}

# Get cluster credentials and set kubectl context
# 1. Get list of cluster names from Azure CLI
# 2. Get credentials for each cluster using az aks get-credentials
get_azure_kube_credentials() {
  if [[ -z "$RESOURCE_GROUP" || -z "$CONTROL_PLANE" ]]; then
    log "error" "Resource group name and control plane name must not be empty."
    exit 1
  fi

  log "info" "Retrieving credentials for all clusters..."

  # Get list of cluster names (don't filter out CONTROL_PLANE)
  clusters=$(az aks list --resource-group "$RESOURCE_GROUP" --query "[].name" -o tsv)

  # Get credentials for each cluster
  for cluster in $clusters; do
    if az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$cluster" --overwrite-existing > /dev/null 2>&1; then
      log "info" "Credentials retrieved successfully for cluster $cluster."
    else
      log "error" "Failed to retrieve credentials for cluster $cluster."
    fi
  done

  log "info" "Credential retrieval for all clusters complete."
}

# Deploy k3d clusters
# 1. Check k3d is installed
# 2. Check CONTROL_PLANE is not empty
# 3. Create docker network edgeClusters if it does not exist. We create this network with
#    docker instead of k3d so we can control the configuration of the network.
# 4. Create k3d CONTROL_PLANE cluster
# 5. Create k3d EDGE_CLUSTER_COUNT edge clusters
deploy_k3d_clusters() {
  local k3dnetwork="edgeClusters"

  # check k3d is installed
  if ! command -v k3d > /dev/null; then
    log "error" "k3d is not installed."
    log "info" "If you'd like to use Azure, use --mode azure or set the MODE environment variable to azure."
    exit 1
  fi

  # check the CONTROL_PLANE is not empty
  if [[ -z "$CONTROL_PLANE" ]]; then
    log "error" "CONTROL_PLANE must not be empty."
    exit 1
  fi

  # if docker network edgeClusters does not exist, create it
  if ! docker network inspect "$k3dnetwork"  > /dev/null 2>&1; then
    log "info" "Creating docker network $k3dnetwork..."
    if docker network create "$k3dnetwork" --driver bridge --ip-range 172.28.0.0/16 --subnet 172.28.0.0/16 --gateway 172.28.0.1 > /dev/null; then
      log "info" "Docker network $k3dnetwork created successfully."
    else
      log "error" "Failed to create docker network $k3dnetwork."
      exit 1
    fi
  else
    log "info" "Docker network $k3dnetwork already exists."
  fi

  # check if the CONTROL_PLANE cluster exists
  if k3d cluster list | grep -q "$CONTROL_PLANE"; then
    log "info" "k3d cluster $CONTROL_PLANE already exists."
  else
    log "info" "Creating k3d cluster $CONTROL_PLANE..."
    if k3d cluster create "$CONTROL_PLANE" --no-lb --k3s-arg --disable=traefik@server:0 --network "$k3dnetwork" > /dev/null; then
      log "info" "k3d cluster $CONTROL_PLANE created successfully."
    else
      log "error" "Failed to create k3d cluster $CONTROL_PLANE."
      exit 1
    fi
  fi

  for ((i=1; i<=EDGE_CLUSTER_COUNT; i++)); do
    cluster="cluster$i"

    #check if the cluster exists
    if k3d cluster list | grep -q "$cluster"; then
      log "info" "k3d cluster $cluster already exists."
    else
      log "info" "Creating k3d cluster $cluster..."
      if k3d cluster create "$cluster" --no-lb --k3s-arg --disable=traefik@server:0 --network "$k3dnetwork" > /dev/null; then
        log "info" "k3d cluster $cluster created successfully."
      else
        log "error" "Failed to create k3d cluster $cluster."
        exit 1
      fi
    fi
  done

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

# Deploy Argo CD, if the argocd namespace does not already exist
# Usage: deploy_argocd
# 1. Set kubectl context to CONTROL_PLANE
# 2. Check if argocd namespace already exists
# 3. Remove ~/.config/argocd directory if it exists
# 4. Create argocd namespace
# 5. Apply Argo CD manifests
# 6. Wait for Argo CD to be ready
# 7. Patch Argo CD to be a LoadBalancer service
deploy_argocd() {
  set_kubectl_context "$CONTROL_PLANE"

  log "info" "Deploying Argo CD..."

  # Check if argocd namespace already exists
  if kubectl get namespace argocd > /dev/null 2>&1; then
    log "info" "Argo CD namespace already exists. Skip deployment."
    return 0
  fi

  # Remove ~/.config/argocd directory if it exists
  if [ -d ~/.config/argocd ]; then
    log "info" "Removing existing Argo CD configuration directory..."
    rm -rf ~/.config/argocd
  fi

  # Create argocd namespace
  if ! kubectl create namespace argocd > /dev/null 2>&1; then
    log "error" "Failed to create argocd namespace."
    exit 1
  fi

  # Apply Argo CD manifests
  if kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml | while read -r line; do log "info" "$line"; done; then
    log "info" "Argo CD manifests applied successfully."
  else
    log "error" "Failed to apply Argo CD manifests."
    exit 1
  fi

  # Wait for argocd-server deployment to be ready
  if kubectl wait deployment argocd-server -n argocd --for condition=available --timeout=90s > /dev/null 2>&1; then
    log "info" "argocd-server deployment is ready."
  else
    log "error" "argocd-server deployment is not ready."
    exit 1
  fi

  # Patch argocd-server service to use LoadBalancer
  if kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "LoadBalancer"}}'  > /dev/null 2>&1; then
    log "info" "argocd-server service patched to use LoadBalancer."
  else
    log "error" "Failed to patch argocd-server service."
    exit 1
  fi

  log "info" "Argo CD installation completed."
}

# Get Argo CD external IP address
# 1. Wait for argocd-server service to have an external IP address
# 2. Get the external IP address
# 3. Set EXTERNAL_IP variable
get_external_ip() {
  # Wait for argocd-server service to have an external IP address
  log "info" "Waiting for an external IP address..."
  
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
  
  log "info" "External IP address: $EXTERNAL_IP"
}

# Login to Argo CD, if not already logged in
# If ARGOCD_PASSWORD is not empty, update password
# 1. Check if argocd is already logged in
# 2. Wait for argocd-initial-admin-secret to be available
# 3. Get plain text password from argocd-initial-admin-secret secret
# 4. Login to Argo CD
# 5. If ARGOCD_PASSWORD is not empty, update password
login_to_argocd() {
  if [[ -z "$EXTERNAL_IP" ]]; then
    log "error" "External IP must not be empty."
    exit 1
  fi

  # Check if argocd is already logged in
  if argocd account get > /dev/null 2>&1; then
    log "info" "Already logged in to Argo CD."
    return 0
  fi

  log "info" "Logging in to Argo CD..."

  # Wait for argocd-initial-admin-secret to be available
  if ! kubectl wait secret --namespace argocd argocd-initial-admin-secret --for=jsonpath='{.type}'=Opaque --timeout=90s > /dev/null 2>&1; then
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
  if ! argocd login "$EXTERNAL_IP" --username admin --password "$adminSecret" --insecure > /dev/null 2>&1; then
    log "error" "Failed to log in to Argo CD."
    exit 1
  fi

  if [ -n "$ARGOCD_PASSWORD" ]; then
    # Update admin password
    if ! argocd account update-password --current-password "$adminSecret" --new-password "$ARGOCD_PASSWORD" > /dev/null 2>&1; then
      log "error" "Failed to update admin password."
      exit 1
    fi
  fi

  log "info" "Logged in to Argo CD successfully."
}

# Add edge clusters to Argo CD
# 1. Get edge clusters by querying kubeconfig contexts, ignore $CONTROL_PLANE
# 2. For each edge cluster, add it to Argo CD
add_argocd_clusters() {
  local edgeClusters
  
  log "info" "Adding edge clusters to Argo CD..."

  # get edgeClusters by querying kubeconfig contexts, ignore $CONTROL_PLANE
  edgeClusters=$(kubectl config get-contexts -o name | grep -v "$CONTROL_PLANE")

  for cluster in $edgeClusters; do
    if argocd cluster add "$cluster" -y  > /dev/null 2>&1; then
      log "info" "Added $cluster to Argo CD successfully."
    else
      log "error" "Failed to add $cluster to Argo CD."
    fi
  done
}

# Deploy Argo CD applications
# For each edge cluster, apply manifests from manifestUrl template
# The template must contain {clustername} placeholder
# 1. Get edge clusters by querying kubeconfig contexts, ignore $CONTROL_PLANE
# 2. For each edge cluster, apply manifests from manifestUrl template
#
# It would be better if we could use the kuttl test framework to apply manifests
# to the edge clusters. However, kuttl does not support applying manifests to
# multiple clusters at the same time. So, we have to use kubectl directly and
# set the context for each cluster.
apply_manifests() {
  local edgeClusters

  # Require resourceGroup, controlPlane, manifestUrl
  if [[ -z "$RESOURCE_GROUP" || -z "$CONTROL_PLANE" || -z "$MANIFEST_URL" ]]; then
    log "error" "Resource group name, control plane name, and Manifest URL template must not be empty."
    exit 1
  fi

  set_kubectl_context "$CONTROL_PLANE"

  # Get list of edge clusters
  edgeClusters=$(kubectl config get-contexts -o name | grep -v "$CONTROL_PLANE")

  # Loop over each cluster and apply manifests
  for cluster in $edgeClusters; do
    local url="${MANIFEST_URL/\{clustername\}/$cluster}"
    if kubectl apply -f "$url" > /dev/null 2>&1; then
      log "info" "Applied manifests for $cluster successfully."
    else
      log "error" "Failed to apply manifests for $cluster."
    fi
  done
}

# Run KUTTL tests, collect results
# 1. Get edge clusters by querying kubeconfig contexts, ignore $CONTROL_PLANE
# 2. For each edge cluster, run KUTTL tests in tests/{cluster} folder
# 3. Collect test results in a temporary folder
# 4. Aggregate test results into a single file in JUnit format
test_deployment() {
  local edgeClusters

  # Require resourceGroup, controlPlane
  if [[ -z "$RESOURCE_GROUP" || -z "$CONTROL_PLANE" ]]; then
    log "error" "Resource group name and control plane name must not be empty."
    exit 1
  fi

  # log info message
  log "info" "Running tests..."

  # Get list of edge clusters
  edgeClusters=$(kubectl config get-contexts -o name | grep -v "$CONTROL_PLANE")

  # Loop over each cluster and run tests
  for cluster in $edgeClusters; do
    set_kubectl_context "$cluster"

    local testFolder="tests/$cluster"
    local reportName="$cluster-$TIMESTAMP"
    if kubectl kuttl test --report JSON --artifacts-dir "$TEMP_DIR" --report-name "$reportName" "$testFolder" > /dev/null 2>&1; then
      log "info" "Tests for $cluster completed."
    else
      log "error" "Tests for $cluster failed."
      EXIT_FLAG=1
    fi
  done
}

# Aggregate test results into a single file in JUnit format
# 1. Get edge clusters by querying kubeconfig contexts, ignore $CONTROL_PLANE
# 2. For each edge cluster, get test results in JSON format
# 3. Aggregate test results into a single file in JUnit format
aggregate_test_results() {
  local total=0 failures=0 errors=0 notRun=0 inconclusive=0 ignored=0 skipped=0 totalTime=0 totalTestSuites=()
  local testResultsName="results-$TIMESTAMP" 
  local testResultsFile="$TEST_RESULTS_DIR/$testResultsName.xml" 
  
  mkdir -p "$TEST_RESULTS_DIR"
  
  edgeClusters=$(kubectl config get-contexts -o name | grep -v "$CONTROL_PLANE")

  for cluster in $edgeClusters; do
    local reportName; reportName="$cluster-$TIMESTAMP" 
    local clusterResultsFile; clusterResultsFile="$TEMP_DIR/$reportName.json"

    log "info" "Parsing test results in $clusterResultsFile"
    
    local testResults; testResults=$(jq -r '.testsuite[] | @base64' "$clusterResultsFile")

    for result in $testResults; do
      local testSuite; testSuite=$(base64 -d <<<"$result") testSuiteName=$(jq -r '.name' <<<"$testSuite")
      log "info" "Parsing test suite $testSuiteName"
      local testSuiteType="KUTTL" 
      local testSuiteTests; testSuiteTests=$(jq -r '.tests' <<<"$testSuite") testSuiteFailures=0 testSuiteErrors=0
      local testSuiteTime; testSuiteTime=$(jq -r '.time' <<<"$testSuite") testSuiteResult="Success" testSuiteSuccess="True"
      local testSuiteTestCases; testSuiteTestCases=$(jq -r '.testcase[] | @base64' <<<"$testSuite") testCases=()

      for item in $testSuiteTestCases; do
        local testCase; testCase=$(base64 -d <<<"$item") 
        local testCaseClassName; testCaseClassName=$(jq -r '.classname' <<<"$testCase")
        local testCaseName; testCaseName=$testCaseClassName-$(jq -r '.name' <<<"$testCase")

        log "info" "Parsing test case $testCaseName"

        local testCaseTime; testCaseTime=$(jq -r '.time' <<<"$testCase") 
        local testCaseAsserts; testCaseAsserts=$(jq -r '.assertions' <<<"$testCase")
        local testCaseFailure; testCaseFailure=$(jq -r '.failure' <<<"$testCase")

        if [ "$testCaseFailure" != "null" ]; then
          local testCaseFailureMessage; testCaseFailureMessage=$(jq -r '.message' <<<"$testCaseFailure")
          local testCaseFailureText; testCaseFailureText=$(jq -r '.text' <<<"$testCaseFailure")
          testCases+=("<test-case name=\"$testCaseName\" executed=\"True\" result=\"Failure\" success=\"False\" time=\"$testCaseTime\" asserts=\"$testCaseAsserts\">
          <failure>
            <message>$testCaseFailureMessage: $testCaseFailureText</message>
          </failure>
          </test-case>")

          log "error" "Test case $testCaseName failed: $testCaseFailureMessage: $testCaseFailureText"

          failures=$((failures + 1)) 
          testSuiteFailures=$((testSuiteFailures + 1))
        else
          testCases+=("<test-case name=\"$testCaseName\" executed=\"True\" result=\"Success\" success=\"True\" time=\"$testCaseTime\" asserts=\"$testCaseAsserts\" />")

          log "info" "Test case $testCaseName passed"
        fi

        total=$((total + 1)) totalTime=$(awk "BEGIN {print $totalTime + $testCaseTime; exit}")
      done

      totalTestSuites+=("<test-suite type=\"$testSuiteType\" name=\"$testSuiteName\" executed=\"True\" result=\"$testSuiteResult\" success=\"$testSuiteSuccess\" time=\"$testSuiteTime\">
      <results>
      $(printf '%s\n' "${testCases[@]}")
      </results>
      </test-suite>")

      log "info" "Test suite $testSuiteName total tests: $testSuiteTests, failures: $testSuiteFailures, errors: $testSuiteErrors, time: $testSuiteTime"

    done # end of test suite loop
  done # end of cluster loop

  # create the test-results xml and save to file
  local testresults
  testresults="<test-results name=\"$testResultsName\" total=\"$total\" errors=\"$errors\" failures=\"$failures\" not-run=\"$notRun\" inconclusive=\"$inconclusive\" ignored=\"$ignored\" skipped=\"$skipped\" time=\"$totalTime\">
  $(printf '%s\n' "${totalTestSuites[@]}")
  </test-results>"

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
  if az group exists --name "$RESOURCE_GROUP" > /dev/null 2>&1; then
    log "info" "Deleting resource group $RESOURCE_GROUP..."
    if az group delete --name "$RESOURCE_GROUP" --yes > /dev/null 2>&1; then
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
    log "info" "Deleting k3d clusters..."
    if k3d cluster delete -a > /dev/null 2>&1; then
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
  steps+=("display_azure_control_plane_values")
  steps+=("get_azure_kube_credentials")
}

command_k3d() {
  steps+=("deploy_k3d_clusters")
  steps+=("modify_k3d_kube_credentials")
}

command_argocd() {
  steps+=("deploy_argocd")
  steps+=("get_external_ip")
  steps+=("login_to_argocd")
  steps+=("add_argocd_clusters")
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
  log "info" "Step timings (s)" "$json"
  exit $EXIT_FLAG
fi

echo ""
printf "%-30s %s\n" "Step" "Duration (s)"
printf "%-30s %s\n" "---------------------" "---------------------"

for name in "${steps[@]}"; do
    printf "%-30s %s\n" "$name" "${timings[$name]}"
done
exit $EXIT_FLAG