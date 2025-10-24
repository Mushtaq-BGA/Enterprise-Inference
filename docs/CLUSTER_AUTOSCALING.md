# 🚀 Production Guide: Configuring the Cluster Autoscaler

Pod-level autoscaling (HPA and Knative's KPA) is essential for handling traffic spikes, but it's only half of the equation. If your cluster runs out of nodes, your pods have nowhere to run. The **Cluster Autoscaler** solves this by automatically adding or removing nodes from your Kubernetes cluster based on resource demand.

This guide provides the foundational steps and configurations for enabling the Cluster Autoscaler on major cloud providers.

## 🎯 Why You Need Cluster Autoscaling

1.  **Cost Efficiency**: Automatically removes underutilized nodes, so you only pay for the resources you actually need.
2.  **High Availability**: When a node fails, the Cluster Autoscaler can provision a new one to reschedule the affected pods.
3.  **True Scalability**: Ensures there is always enough capacity to accommodate scaling events from KServe models and the LiteLLM router, even during massive traffic surges.

---

## ☁️ Cloud Provider Implementations

The Cluster Autoscaler requires cloud-specific permissions and configuration. Below are the setup guides for AWS, Azure, and GCP.

### 1. Amazon Web Services (AWS) - EKS

The Cluster Autoscaler integrates with **Auto Scaling Groups (ASGs)**.

#### a. IAM Permissions

Create an IAM policy that grants the Cluster Autoscaler permissions to manage ASGs.

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "autoscaling:DescribeAutoScalingGroups",
                "autoscaling:DescribeAutoScalingInstances",
                "autoscaling:DescribeLaunchConfigurations",
                "autoscaling:DescribeTags",
                "autoscaling:SetDesiredCapacity",
                "autoscaling:TerminateInstanceInAutoScalingGroup",
                "ec2:DescribeLaunchTemplateVersions"
            ],
            "Resource": "*"
        }
    ]
}
```

#### b. Associate IAM Role with Service Account

Use `eksctl` or the AWS console to associate this IAM role with the `cluster-autoscaler` service account in the `kube-system` namespace.

```bash
eksctl create iamserviceaccount \
  --name cluster-autoscaler \
  --namespace kube-system \
  --cluster <YOUR_EKS_CLUSTER_NAME> \
  --attach-policy-arn <YOUR_POLICY_ARN> \
  --approve
```

#### c. Tag Your Auto Scaling Groups

The Cluster Autoscaler needs to know which ASGs it can manage. Add the following tags to your node group ASGs:

- `k8s.io/cluster-autoscaler/enabled`: `true`
- `k8s.io/cluster-autoscaler/<YOUR_EKS_CLUSTER_NAME>`: `owned`

#### d. Deploy the Cluster Autoscaler

Deploy the official Helm chart, making sure to customize the `clusterName`, `awsRegion`, and `serviceAccount.name`.

```bash
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm install cluster-autoscaler autoscaler/cluster-autoscaler \
  --namespace kube-system \
  --set autoDiscovery.clusterName=<YOUR_EKS_CLUSTER_NAME> \
  --set awsRegion=<YOUR_AWS_REGION> \
  --set rbac.create=true \
  --set serviceAccount.create=false \
  --set serviceAccount.name=cluster-autoscaler
```

---

### 2. Microsoft Azure - AKS

On AKS, the Cluster Autoscaler is a managed feature that you can enable directly on your node pools.

#### a. Enable Cluster Autoscaler on a Node Pool

Use the Azure CLI to enable autoscaling for a specific node pool.

```bash
# Enable on an existing node pool
az aks nodepool update \
  --resource-group <YOUR_RESOURCE_GROUP> \
  --cluster-name <YOUR_AKS_CLUSTER_NAME> \
  --name <YOUR_NODE_POOL_NAME> \
  --enable-cluster-autoscaler \
  --min-count 1 \
  --max-count 10

# Or create a new autoscaling-enabled node pool
az aks nodepool add \
  --resource-group <YOUR_RESOURCE_GROUP> \
  --cluster-name <YOUR_AKS_CLUSTER_NAME> \
  --name <NEW_NODE_POOL_NAME> \
  --enable-cluster-autoscaler \
  --min-count 1 \
  --max-count 10
```

#### b. Configure Autoscaling Profile (Optional)

You can fine-tune the autoscaler's behavior by adjusting its profile settings.

```bash
az aks update \
  --resource-group <YOUR_RESOURCE_GROUP> \
  --name <YOUR_AKS_CLUSTER_NAME> \
  --cluster-autoscaler-profile \
    scan-interval=30s \
    scale-down-unneeded-time=5m \
    scale-down-delay-after-add=10m \
    new-pod-scale-up-delay=10s
```

---

### 3. Google Cloud Platform (GCP) - GKE

Like AKS, GKE offers cluster autoscaling as a managed feature integrated with **Managed Instance Groups (MIGs)**.

#### a. Enable Autoscaling on a Node Pool

Use the `gcloud` CLI to enable autoscaling.

```bash
# Enable on an existing node pool
gcloud container node-pools update <YOUR_NODE_POOL_NAME> \
  --cluster=<YOUR_GKE_CLUSTER_NAME> \
  --zone=<YOUR_GCP_ZONE> \
  --enable-autoscaling \
  --min-nodes=1 \
  --max-nodes=10

# Or create a new autoscaling-enabled node pool
gcloud container node-pools create <NEW_NODE_POOL_NAME> \
  --cluster=<YOUR_GKE_CLUSTER_NAME> \
  --zone=<YOUR_GCP_ZONE> \
  --enable-autoscaling \
  --min-nodes=1 \
  --max-nodes=10
```

#### b. Verify Autoscaling

You can check the status of your node pools in the GCP Console or via the CLI:

```bash
gcloud container clusters describe <YOUR_GKE_CLUSTER_NAME> --zone=<YOUR_GCP_ZONE>
```

---

## ✅ Verification

After setting up the Cluster Autoscaler, you can verify it's working by:

1.  **Checking the logs**:
    ```bash
    # For AWS (Helm deployment)
    kubectl -n kube-system logs -f deployment/cluster-autoscaler
    ```

2.  **Triggering a scale-up event**: Deploy a large number of pods that cannot be scheduled on the current nodes.
    ```bash
    # Example: Create a dummy deployment with high resource requests
    kubectl create deployment dummy-load --image=nginx --replicas=20
    kubectl set resources deployment dummy-load --requests=cpu=1,memory=2Gi
    ```

Watch for new nodes being provisioned in your cloud provider's console. Once you delete the dummy deployment, the Cluster Autoscaler should automatically scale the cluster back down after a configurable period (e.g., 10 minutes).
