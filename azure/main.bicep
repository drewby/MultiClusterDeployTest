param edgeClusterCount int = 3

@description('The location of the Managed Cluster resource.')
param location string = resourceGroup().location

@description('User name for the Linux Virtual Machines.')
param linuxAdminUsername string

@description('Configure all linux machines with the SSH RSA public key string. Your key should include three parts, for example \'ssh-rsa AAAAB...snip...UcyupgH azureuser@linuxvm\'')
param sshRSAPublicKey string

module controlPlane 'cluster.bicep' = {
  name: 'controlPlane'
  params: {
    clusterName: 'controlPlane'
    location: location
    dnsPrefix: 'controlPlane'
    linuxAdminUsername: linuxAdminUsername
    sshRSAPublicKey: sshRSAPublicKey
  }
}

// create edgeClusterCount of edge clusters using the same module
module edgeCluster 'cluster.bicep' = [for i in range(1, edgeClusterCount): {
  name: 'cluster${i}'
  params: {
    clusterName: 'cluster${i}'
    location: location
    dnsPrefix: 'cluster${i}'
    linuxAdminUsername: linuxAdminUsername
    sshRSAPublicKey: sshRSAPublicKey
  }
}]

output controlPlaneName string = controlPlane.outputs.clusterName
output controlPlaneFQDN string = controlPlane.outputs.clusterFQDN
