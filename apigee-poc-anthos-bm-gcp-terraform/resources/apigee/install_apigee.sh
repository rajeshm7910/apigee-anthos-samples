#!/bin/bash


wait_for_active() {
        operations_id=$1
	if [ $operations_id != null ]; then
        echo "Checking Operations : " $operations_id
        status=$(gcloud alpha apigee operations describe $operations_id --format=json | jq -r .response.state)
        while [ "$status"  != "ACTIVE"  ] 
        do
                sleep 30
        	echo "Checking Operations : " $operations_id
        	status=$(gcloud alpha apigee operations describe $operations_id --format=json | jq -r .response.state)
        done
	fi
}

create_workspace() {
  export KUBECONFIG=$PWD/bmctl-workspace/apigee-hybrid/apigee-hybrid-kubeconfig
  mkdir apigee_workspace
  cd apigee_workspace
  export APIGEE_WORKSPACE=$PWD
}
install_kpt() {
curl -L https://github.com/GoogleContainerTools/kpt/releases/download/v0.39.2/kpt_linux_amd64 > kpt_0_39_2
   chmod +x kpt_0_39_2
   # alias kpt="$(readlink -f kpt_0_39_2)"
   sudo mv kpt_0_39_2 /usr/local/bin/kpt
}

install_cert_manager()
{
	kubectl apply --validate=false -f https://github.com/jetstack/cert-manager/releases/download/v1.2.0/cert-manager.yaml
}

download_asm() {
	curl -LO https://storage.googleapis.com/gke-release/asm/istio-1.10.6-asm.2-linux-amd64.tar.gz
	tar xzf istio-1.10.6-asm.2-linux-amd64.tar.gz
	cd istio-1.10.6-asm.2
}

enable_services() 
{
gcloud services enable \
  anthos.googleapis.com \
  cloudtrace.googleapis.com \
  cloudresourcemanager.googleapis.com \
  container.googleapis.com \
  compute.googleapis.com \
  gkeconnect.googleapis.com \
  gkehub.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  logging.googleapis.com \
  meshca.googleapis.com \
  meshtelemetry.googleapis.com \
  meshconfig.googleapis.com \
  monitoring.googleapis.com \
  stackdriver.googleapis.com \
  sts.googleapis.com
}

enable_apigee_services() {

 gcloud services enable \
    apigee.googleapis.com \
    apigeeconnect.googleapis.com \
    dns.googleapis.com \
    pubsub.googleapis.com \
    cloudresourcemanager.googleapis.com \
    compute.googleapis.com \
    container.googleapis.com
}

initialize_mesh() {
IDENTITY_PROVIDER="$(kubectl get memberships.hub.gke.io membership -o=jsonpath='{.spec.identity_provider}')"

IDENTITY="$(echo "${IDENTITY_PROVIDER}" | sed 's/^https:\/\/gkehub.googleapis.com\/projects\/\(.*\)\/locations\/global\/memberships\/\(.*\)$/\1 \2/g')"

read -r ENVIRON_PROJECT_ID HUB_MEMBERSHIP_ID <<EOF
${IDENTITY}
EOF

POST_DATA='{"workloadIdentityPools":["'${ENVIRON_PROJECT_ID}'.hub.id.goog","'${ENVIRON_PROJECT_ID}'.svc.id.goog"]}'

curl --request POST \
  --header "Content-Type: application/json" \
  --header "Authorization: Bearer $(gcloud auth print-access-token)" \
  --data "${POST_DATA}" \
https://meshconfig.googleapis.com/v1alpha1/projects/${ENVIRON_PROJECT_ID}:initialize
}

configure_mesh() {
kpt pkg get \
https://github.com/GoogleCloudPlatform/anthos-service-mesh-packages.git/asm@release-1.10-asm asm

ENVIRON_PROJECT_NUMBER=$(gcloud projects describe "${ENVIRON_PROJECT_ID}" --format="value(projectNumber)")

CLUSTER_NAME="${HUB_MEMBERSHIP_ID}"

CLUSTER_LOCATION="global"

HUB_IDP_URL="$(kubectl get memberships.hub.gke.io membership -o=jsonpath='{.spec.identity_provider}')"

kpt cfg set asm gcloud.core.project ${ENVIRON_PROJECT_ID}
kpt cfg set asm gcloud.container.cluster ${CLUSTER_NAME}
kpt cfg set asm gcloud.compute.location ${CLUSTER_LOCATION}
kpt cfg set asm anthos.servicemesh.hub gcr.io/gke-release/asm
kpt cfg set asm anthos.servicemesh.rev asm-1106-2
kpt cfg set asm anthos.servicemesh.tag 1.10.6-asm.2
kpt cfg set asm gcloud.project.environProjectNumber ${ENVIRON_PROJECT_NUMBER}
kpt cfg set asm anthos.servicemesh.hubTrustDomain ${ENVIRON_PROJECT_ID}.svc.id.goog
kpt cfg set asm anthos.servicemesh.hub-idp-url "${HUB_IDP_URL}"

}

install_asm() {

  bin/istioctl install -y  \
  -f asm/istio/istio-operator.yaml \
  -f asm/istio/options/hub-meshca.yaml --revision=asm-1106-2

}

post_install_asm() {

cat <<EOF > istiod-service.yaml
apiVersion: v1
kind: Service
metadata:
 name: istiod
 namespace: istio-system
 labels:
   istio.io/rev: asm-1106-2
   app: istiod
   istio: pilot
   release: istio
spec:
 ports:
   - port: 15010
     name: grpc-xds # plaintext
     protocol: TCP
   - port: 15012
     name: https-dns # mTLS with k8s-signed cert
     protocol: TCP
   - port: 443
     name: https-webhook # validation and injection
     targetPort: 15017
     protocol: TCP
   - port: 15014
     name: http-monitoring # prometheus stats
     protocol: TCP
 selector:
   app: istiod
   istio.io/rev: asm-1106-2
EOF
}

install_apigee_ctl() {

cd $APIGEE_WORKSPACE
export VERSION=$(curl -s \
	    https://storage.googleapis.com/apigee-release/hybrid/apigee-hybrid-setup/current-version.txt?ignoreCache=1)

curl -LO \
	    https://storage.googleapis.com/apigee-release/hybrid/apigee-hybrid-setup/$VERSION/apigeectl_linux_64.tar.gz

tar -xvf apigeectl_linux_64.tar.gz
mv apigeectl_$VERSION-* apigeectl

}


setup_project_directory() {
	cd $APIGEE_WORKSPACE/apigeectl
	export APIGEECTL_HOME=$PWD
	echo $APIGEECTL_HOME

	cd $APIGEE_WORKSPACE
	mkdir hybrid-files
	cd hybrid-files
	mkdir overrides
	mkdir certs
	ln -s $APIGEECTL_HOME/tools tools
	ln -s $APIGEECTL_HOME/config config
	ln -s $APIGEECTL_HOME/templates templates
	ln -s $APIGEECTL_HOME/plugins plugins
	#Lets do cleaup first
	export PROJECT_ID=$(gcloud config get-value project)
	#gcloud iam service-accounts delete  apigee-non-prod@$PROJECT_ID.iam.gserviceaccount.com --quiet
	echo 'y' | ./tools/create-service-account --env non-prod --dir ./service-accounts
	gcloud iam service-accounts keys create ./service-accounts/$PROJECT_ID-apigee-non-prod.json --iam-account=apigee-non-prod@$PROJECT_ID.iam.gserviceaccount.com --quiet
	export INGRESS_HOST=$(kubectl -n istio-system get service istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
	export DOMAIN=$INGRESS_HOST".nip.io"
	
	openssl req  -nodes -new -x509 -keyout ./certs/keystore.key -out \
		    ./certs/keystore.pem -subj '/CN='$DOMAIN'' -days 3650

}

setup_org_env() {
	cd $APIGEE_WORKSPACE	
	TOKEN=$(gcloud auth print-access-token)
	export PROJECT_ID=$(gcloud config get-value project)
	export ORG_NAME=$PROJECT_ID
	ORG_DISPLAY_NAME="demo-org"
	ORGANIZATION_DESCRIPTION="demo-org"
	export ANALYTICS_REGION=us-central1
	export RUNTIMETYPE=HYBRID
 	curl -H "Authorization: Bearer $TOKEN" -X POST -H "content-type:application/json" \
  	-d '{
    		"name":"'"$ORG_NAME"'",
    		"displayName":"'"$ORG_DISPLAY_NAME"'",
    		"description":"'"$ORGANIZATION_DESCRIPTION"'",
    		"runtimeType":"'"$RUNTIMETYPE"'",
    		"analyticsRegion":"'"$ANALYTICS_REGION"'"
  	}' -o org.json \
  	"https://apigee.googleapis.com/v1/organizations?parent=projects/$PROJECT_ID"

	operations_id=$(cat org.json | jq -r .name | awk -F "/" '{print $NF}')
        wait_for_active $operations_id

	
	export ENV_NAME=test
	ENV_DISPLAY_NAME=test
	ENV_DESCRIPTION=test
	curl -H "Authorization: Bearer $TOKEN" -X POST -H "content-type:application/json"   -d '{
    		"name": "'"$ENV_NAME"'",
    		"displayName": "'"$ENV_DISPLAY_NAME"'",
    		"description": "'"$ENV_DESCRIPTION"'"
  	}' -o env.json  "https://apigee.googleapis.com/v1/organizations/$ORG_NAME/environments"	
	
	operations_id=$(cat env.json | jq -r .name | awk -F "/" '{print $NF}')
        wait_for_active $operations_id
	
	
 	export ENV_GROUP=default-test
	export INGRESS_HOST=$(kubectl -n istio-system get service istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
	export DOMAIN=$INGRESS_HOST".nip.io"

	curl -H "Authorization: Bearer $TOKEN" -X POST -H "content-type:application/json" \
   	-d '{
     		"name": "'"$ENV_GROUP"'",
     		"hostnames":["'"$DOMAIN"'"]
   	}' -o envgroup.json \
   	"https://apigee.googleapis.com/v1/organizations/$ORG_NAME/envgroups"
	operations_id=$(cat envgroup.json | jq -r .name | awk -F "/" '{print $NF}')
        wait_for_active $operations_id
	
	
        curl  -H "Authorization: Bearer $TOKEN" -X POST -H "content-type:application/json" \
   	-d '{
     		"environment": "'"$ENV_NAME"'",
   	}'  -o envattach.json \
   		"https://apigee.googleapis.com/v1/organizations/$ORG_NAME/envgroups/$ENV_GROUP/attachments"
	
	
    
}

patch_standard_storageclass() {


	kubectl patch storageclass standard \
		  -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
}

prepare_overrides_files() {
	cd $APIGEE_WORKSPACE
	export PROJECT_ID=$(gcloud config get-value project)
	wget https://github.com/mikefarah/yq/releases/download/v4.24.2/yq_linux_amd64
	chmod +x yq_linux_amd64
	sudo mv yq_linux_amd64 /usr/local/bin/yq
	cp apigeectl/examples/overrides-small.yaml hybrid-files/overrides/overrides.yaml
	cd hybrid-files/overrides/
	yq -i '.gcp.projectID = env(PROJECT_ID)' overrides.yaml
	yq -i '.org = env(PROJECT_ID)' overrides.yaml
	yq -i '.k8sCluster.name = "apigee-hybrid"' overrides.yaml
	yq -i '.k8sCluster.region = "us-central1-a"' overrides.yaml
	yq -i '.instanceID = "apigee-hybrid-demo"' overrides.yaml
	yq -i '.cassandra.hostNetwork = false' overrides.yaml
	yq -i 'del(.virtualhosts.[].sslSecret)' overrides.yaml
	yq -i '.virtualhosts.[].name = "default-test"' overrides.yaml
	yq -i '.virtualhosts.[].sslCertPath = "./certs/keystore.pem"' overrides.yaml
	yq -i '.virtualhosts.[].sslKeyPath = "./certs/keystore.key"' overrides.yaml
	
	
	export SVC_ACCOUNT="./service-accounts/"$PROJECT_ID"-apigee-non-prod.json"
	echo $SVC_ACCOUNT
	yq -i '.envs.[].serviceAccountPaths.synchronizer = env(SVC_ACCOUNT)' overrides.yaml
	yq -i '.envs.[].serviceAccountPaths.udca = env(SVC_ACCOUNT)' overrides.yaml
	yq -i '.envs.[].serviceAccountPaths.runtime = env(SVC_ACCOUNT)' overrides.yaml
	yq -i '.mart.serviceAccountPath = env(SVC_ACCOUNT)' overrides.yaml
	yq -i '.metrics.serviceAccountPath = env(SVC_ACCOUNT)' overrides.yaml
	yq -i '.connectAgent.serviceAccountPath = env(SVC_ACCOUNT)' overrides.yaml
	yq -i '.watcher.serviceAccountPath = env(SVC_ACCOUNT)' overrides.yaml
	yq e '{"udca" : {"serviceAccountPath" : env(SVC_ACCOUNT)}}'  overrides.yaml >> overrides.yaml


}

enable_synchronizer() {
	cd $APIGEE_WORKSPACE
        TOKEN=$(gcloud auth print-access-token)
        export PROJECT_ID=$(gcloud config get-value project)
        export ORG_NAME=$PROJECT_ID

        curl -X POST -H "Authorization: Bearer ${TOKEN}" \
          -H "Content-Type:application/json" \
                "https://apigee.googleapis.com/v1/organizations/${ORG_NAME}:setSyncAuthorization" \
                -d '{"identities":["'"serviceAccount:apigee-non-prod@${ORG_NAME}.iam.gserviceaccount.com"'"]}'

}


wait_for_apigee_ready() {
export APIGEECTL_HOME=$APIGEE_WORKSPACE/apigeectl
cd $APIGEE_WORKSPACE/hybrid-files/

status=$($APIGEECTL_HOME/apigeectl check-ready -f overrides/overrides.yaml 2>&1)
#apigee_ready=$(echo $status | grep 'All containers are ready.')
apigee_ready=""

while [  "$apigee_ready" == "" ]; 
do
        sleep 30
        echo "Checking Apigee Containers ..."
        status=$($APIGEECTL_HOME/apigeectl check-ready -f overrides/overrides.yaml 2>&1)
        apigee_ready=$(echo $status | grep 'All containers are ready.')
done

echo "Apigee is Ready" 

}

install_runtime() {

        cd $APIGEE_WORKSPACE/apigeectl
        export APIGEECTL_HOME=$PWD
        echo $APIGEECTL_HOME
        cd ../hybrid-files/
	kubectl create namespace apigee
	kubectl create namespace apigee-system
        ${APIGEECTL_HOME}/apigeectl init -f overrides/overrides.yaml
	sleep 30
        ${APIGEECTL_HOME}/apigeectl apply -f overrides/overrides.yaml
	wait_for_apigee_ready

}


create_workspace
enable_services
enable_apigee_services
install_kpt
install_cert_manager
download_asm
initialize_mesh
configure_mesh
install_asm
post_install_asm
install_apigee_ctl
setup_project_directory
setup_org_env
patch_standard_storageclass
prepare_overrides_files
enable_synchronizer
install_runtime
