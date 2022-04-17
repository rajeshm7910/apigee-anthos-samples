#!/bin/bash

export project=$(gcloud config get-value project)

apply_constraints() {

	gcloud beta resource-manager org-policies disable-enforce compute.requireShieldedVm --project=${project}
	gcloud beta resource-manager org-policies disable-enforce compute.requireOsLogin --project=${project}
	gcloud beta resource-manager org-policies disable-enforce iam.disableServiceAccountCreation --project=${project}
	gcloud beta resource-manager org-policies disable-enforce iam.disableServiceAccountKeyCreation --project=${project}
	gcloud beta resource-manager org-policies disable-enforce compute.skipDefaultNetworkCreation --project=${project}


	declare -a policies=( "constraints/compute.trustedImageProjects"
				"constraints/compute.vmExternalIpAccess"
                "constraints/compute.restrictSharedVpcSubnetworks"
                "constraints/compute.restrictSharedVpcHostProjects"
                "constraints/compute.restrictVpcPeering"
                "constraints/compute.vmCanIpForward"
                )

	for policy in "${policies[@]}"
	do
cat <<EOF > new_policy.yaml
constraint: $policy
listPolicy:
 allValues: ALLOW
EOF
	gcloud resource-manager org-policies set-policy new_policy.yaml --project="${project}"
	done
}

apply_firewall_policies() {

	gcloud compute firewall-rules create default-allow-ssh --network default --allow tcp:22 --source-ranges 0.0.0.0/0
	gcloud compute firewall-rules create default-allow-rdp --network default --allow tcp:3389 --source-ranges 0.0.0.0/0
	gcloud compute firewall-rules create default-allow-icmp --network default --allow icmp --source-ranges 0.0.0.0/0
	gcloud compute firewall-rules create default-allow-internal --network default --allow tcp:0-65535,udp:0-65535,icmp --source-ranges 10.128.0.0/9
	gcloud compute firewall-rules create default-allow-out --direction egress --priority 0 --network default --allow tcp,udp --destination-ranges 0.0.0.0/0

}

apply_constraints
apply_firewall_policies
