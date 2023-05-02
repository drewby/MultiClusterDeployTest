# Multi-Cluster Deployment Tester

This project allows users to test multi-cluster deployments. The tool deploys clusters using either k3d or Azure, and then deploys Argo CD and edge clusters, applies manifests, and runs tests.

## Dev Container

A Visual Studio Code .devcontainer exists with all the 
Prerequisites. The dev container may also be used in
GitHub codespaces.

## Prerequisites

- kubectl
- kuttl
- argocd CLI
- docker (if deploying with k3d)
- k3d (if deploying with k3d)
- azure CLI (if deploying to azure)

## Usage

The tool is executed by running `./test-harness.sh` followed by a command and any desired options.

The default is to use k3d for deployment. If you want to deploy to azure, use
`--mode azure` from the command line, or set the `MODE` environment variable.

The available commands are:

- `all`: Deploys clusters, Argo CD, manifests, and runs tests
- `k3d`: Deploys k3d infrastructure
- `azure`: Deploys Azure infrastructure
- `argocd`: Deploys Argo CD and edge clusters
- `manifests`: Applies edge cluster manifests
- `test`: Runs tests
- `delete`: Deletes Azure infrastructure

The available options are:

- `-m, --mode <value>`: Mode to deploy clusters, can be k3d or azure (default: k3d)
- `-n, --edge-cluster-count <value>`: Number of edge clusters to deploy (default: 3)
- `-r, --resource-group <value>`: Azure resource group (default: argoCdDemo)
- `-l, --location <value>`: Azure location (default: eastus)
- `-d, --deployment-name <value>`: Name of Azure deployment (default: argoCdDemo)
- `-a, --admin-username <value>`: Linux admin username (default: azureuser)
- `-c, --control-plane <value>`: Name of control plane cluster (default: controlPlane)
- `-u, --manifest-url <value>`: URL to edge cluster manifests (required if MANIFEST_URL environment variable not set)
- `-p, --argocd-password <value>`: Password for Argo CD (default: none)
- `-j, --json-logs`: Output logs in JSON format
- `-o, --output <value>`: Output directory for test results (default: ./test-results)
- `-y, --yes`: Skip confirmation prompt
- `-h, --help`: Display usage

## Environment variables

The tool also accepts several environment variables, which take precedence over the defaults:

- `MODE`: Mode to deploy clusters, can be k3d or azure
- `EDGE_CLUSTER_COUNT`: Number of edge clusters to deploy
- `RESOURCE_GROUP`: Azure resource group
- `LOCATION`: Azure location
- `DEPLOYMENT_NAME`: Name of Azure deployment
- `LINUX_ADMIN_USERNAME`: Linux admin username
- `CONTROL_PLANE`: Name of control plane cluster
- `MANIFEST_URL`: URL to edge cluster manifests
- `ARGOCD_PASSWORD`: Password for Argo CD
- `SSH_PUBLIC_KEY`: Public SSH key
- `JSON_LOGS`: Output logs in JSON format
- `TEST_RESULTS_DIR`: Output directory for test results

## License

This project is licensed under the MIT License.
