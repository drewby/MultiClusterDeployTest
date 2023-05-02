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

**Note:** The `all` command does everything except delete the infrastructure.

The available commands are:

- `all`: Deploys clusters, Argo CD, manifests, and runs tests
- `k3d`: Deploys k3d infrastructure
- `azure`: Deploys Azure infrastructure
- `argocd`: Deploys Argo CD and edge clusters
- `manifests`: Applies edge cluster manifests
- `test`: Runs tests
- `delete`: Deletes k3d or Azure infrastructure

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

## Manifests URL

The MANIFEST_URL environment variable is used to apply a set
of manifests to the cluster before tests are run. An example 
template looks like:

```
https://raw.githubusercontent.com/drewby/argocd-manifests/main/{clustername}/manifest.yaml
```

It would be better if we could use the kuttl test framework to apply manifests
to the edge clusters. However, kuttl does not support applying manifests to
multiple clusters at the same time. So, we have to use kubectl directly and
set the context for each cluster. 

## How to Create Tests

[KUTTL](https://kuttl.dev/) is a tool for testing Kubernetes applications. In this project, we use KUTTL to test the application deployed to our edge clusters. Tests are written in YAML files and stored in the `tests/{cluster}/{testname}` directory. 

Each test consists of one or more asserts, which define the expected state of a Kubernetes resource after the application is deployed. For example, the following assert checks that a deployment named `app1` has three ready replicas:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  namespace: default
  name: app1
status:
  readyReplicas: 3
```

This assert only checks that an appplication with `name` *app1* exists in the *default* `namespace` and that
the `readyReplicas` field of the `status` section of the `Deployment` resource. If there are other fields in 
the manifest that you want to check, you would need to include them in the assert.

Asserts can also test for other kinds of kubernetes objects. For example, a Service:

```yaml
apiVersion: v1
kind: Service
metadata:
  namespace: default
  name: app1
spec:
  type: ClusterIP
  ports:
  - port: 80
  selector:
    app: app1
```

For more information on writing assert YAML files for KUTTL, please refer to the [official KUTTL documentation](https://kuttl.dev/docs/testing/asserts-errors.html).

## Commands and their steps

### **azure** Command

The `azure` command has the following steps:

1. `login_to_azure`: Log into Azure using the Azure CLI. This is necessary to access Azure resources and deploy the infrastructure.

2. `generate_ssh_key`: Generate a public and private SSH key pair to be used with the Azure virtual machines.

3. `create_resource_group`: Create an Azure resource group to hold the resources that will be deployed for this project.

4. `deploy_azure_infra`: Deploy the Azure infrastructure, including virtual networks, virtual machines, and load balancers.

5. `display_azure_control_plane_values`: Display the values of the control plane cluster that was created in Azure. This information can be helpful in further configuring the infrastructure.

6. `get_azure_kube_credentials`: Retrieve the Kubernetes credentials for the Azure cluster. These credentials are necessary to connect to and manage the cluster using kubectl.

### **k3d** Command

The `k3d` command has the following steps:

1. `deploy_k3d_clusters`: Deploy k3d infrastructure, including a control plane cluster and edge clusters.

2. `modify_k3d_kube_credentials`: Modify the kubectl configuration file to match context names to cluster names and fix server addresses.

### **argocd** Command

The `argocd` command has the following steps:

1. `deploy_argocd`: Deploy Argo CD to the control plane cluster.

2. `get_external_ip`: Retrieve the external IP address of the Argo CD service.

3. `login_to_argocd`: Log in to Argo CD using the CLI and the external IP address. If ARGOCD_PASSWORD (or -p option) is set, update the argoCD admin password.

4. `add_argocd_clusters`: Add the edge clusters to Argo CD as clusters to manage.

### Manifests Command

The `manifests` command manifests to the clusters: 

It uses a template to apply a manifest to the cluster. The template is a string provided in MANIFEST_URL environment variable
or on the command line using `-u` or `--manifest-url` and has a replacement variable `{clustername}`.

The following is an example manifest URL template:

```
https://raw.githubusercontent.com/drewby/argocd-manifests/main/{clustername}/manifest.yaml
```

### **test** Command

The `test` command has the following steps:

1. `test_deployment`: Apply the manifests to the edge clusters and run the tests against them.

2. `aggregate_test_results`: Aggregate the results of the tests and output them to a Junit file.

### **delete** Command

The `delete` command has the following steps:

1. Confirmation prompt: If confirmation is not skipped, ask the user if they're sure they want to delete the Azure resource group.

2. `delete_azure_resource_group`: If MODE is `azure`, delete the Azure resource group and all resources within it.

3. `delete_k3d_clusters`: If MODE is `k3d`, Delete the k3d clusters and all associated resources.

4. `delete_kubeconfig`: Remove the kubeconfig context for the deleted clusters.

5. `delete_argocd`: Remove the edge clusters from Argo CD, if applicable.

## License

This project is licensed under the MIT License.
