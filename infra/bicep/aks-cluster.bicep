// Arc-Enabled AKS Cluster on Azure Local with GPU node pool
// Note: AKS Arc clusters are provisioned via `az aksarc create`, not Bicep.
// This module is a reference placeholder that validates the cluster exists.

@description('AKS cluster name')
param clusterName string

@description('Azure Local custom location resource ID')
param customLocationId string

// AKS Arc clusters are created via CLI:
//   az aksarc create -n <name> -g <rg> --custom-location <cl> --vnet-ids <vnet>
//   az aksarc nodepool add -n gpupool --cluster-name <name> -g <rg> --node-count 1 --os-type Linux

output clusterName string = clusterName
output customLocationId string = customLocationId
