@description('A command separated list of edge cluster names to create.')
param edgeClusterNames string = 'cluster1,cluster2,cluster3'

@description('The location of the Managed Cluster resource.')
param location string = resourceGroup().location

@description('User name for the Linux Virtual Machines.')
param linuxAdminUsername string

@description('Configure all linux machines with the SSH RSA public key string. Your key should include three parts, for example \'ssh-rsa AAAAB...snip...UcyupgH azureuser@linuxvm\'')
param sshRSAPublicKey string

@description('Create a control plane cluster')
param enableControlPlane bool = false

// if enableControlPlane is true, create a control plane cluster
module controlPlane 'cluster.bicep' = if (enableControlPlane) {
  name: 'controlPlane'
  params: {
    clusterName: 'controlPlane'
    location: location
    dnsPrefix: 'controlPlane'
    linuxAdminUsername: linuxAdminUsername
    sshRSAPublicKey: sshRSAPublicKey
  }
}

// split the comma separated list of edge cluster names into an array
var clusterNames = split(edgeClusterNames, ',')

// create edgeClusterCount of edge clusters using the same module
module edgeCluster 'cluster.bicep' = [for name in clusterNames: {
  name: 'cluster-${name}'
  params: {
    clusterName: name
    location: location
    dnsPrefix: name
    linuxAdminUsername: linuxAdminUsername
    sshRSAPublicKey: sshRSAPublicKey
  }
}]
