# KED (Kubernetes Ephemeral Disk)

This tool is designed to be a super lightweight and easy way to provision disks in your Kubernetes cluster for use with [kubernetes-sigs/sig-storage-local-static-provisioner](https://github.com/kubernetes-sigs/sig-storage-local-static-provisioner).

It started as a fork of [brunsgaard/eks-nvme-ssd-provisioner](https://github.com/brunsgaard/eks-nvme-ssd-provisioner), but I didn't like the fact that it required labeling and was more "out of the box" ready for EKS. I personally use Rancher, which doesn't provide the labels.

I also plan on expanding this later for a large Elasticsearch cluster I'm running on i3 instances in AWS.
