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
  echo "export KUBECONFIG=$KUBECONFIG" >> ~/.bashrc
  echo "export KUBECONFIG=$KUBECONFIG" >> /home/tfadmin/.bashrc
  mkdir apigee_workspace
  cd apigee_workspace
  export APIGEE_WORKSPACE=$PWD
}


install_cert_manager()
{
	kubectl apply --validate=false -f https://github.com/jetstack/cert-manager/releases/download/v1.7.2/cert-manager.yaml
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


download_asm() {
  cd $APIGEE_WORKSPACE
  curl https://storage.googleapis.com/csm-artifacts/asm/asmcli_1.12 > asmcli
  chmod +x asmcli

}

install_asm() {

cd $APIGEE_WORKSPACE
fleet_id=$(gcloud config get-value project)
echo $KUBECONFIG
echo $fleet_id

./asmcli install --fleet_id ${fleet_id} --kubeconfig $KUBECONFIG --output_dir .  --custom_overlay overlay.yaml  --platform multicloud  --enable_all  --option legacy-default-ingressgateway

}

create_overlay_asm() {

cd $APIGEE_WORKSPACE
cat <<EOF > overlay.yaml
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  components:
    ingressGateways:
      - name: istio-ingressgateway
        enabled: true
        k8s:
          nodeSelector:
            # default node selector, if different or not using node selectors, change accordingly.
            #cloud.google.com/gke-nodepool: apigee-runtime
          resources:
            requests:
              cpu: 1000m
          service:
            type: LoadBalancer
            ports:
              - name: http-status-port
                port: 15021
              - name: http2
                port: 80
                targetPort: 8080
              - name: https
                port: 443
                targetPort: 8443
  meshConfig:
    accessLogFormat:
      '{"start_time":"%START_TIME%","remote_address":"%DOWNSTREAM_DIRECT_REMOTE_ADDRESS%","user_agent":"%REQ(USER-AGENT)%","host":"%REQ(:AUTHORITY)%","request":"%REQ(:METHOD)% %REQ(X-ENVOY-ORIGINAL-PATH?:PATH)% %PROTOCOL%","request_time":"%DURATION%","status":"%RESPONSE_CODE%","status_details":"%RESPONSE_CODE_DETAILS%","bytes_received":"%BYTES_RECEIVED%","bytes_sent":"%BYTES_SENT%","upstream_address":"%UPSTREAM_HOST%","upstream_response_flags":"%RESPONSE_FLAGS%","upstream_response_time":"%RESPONSE_DURATION%","upstream_service_time":"%RESP(X-ENVOY-UPSTREAM-SERVICE-TIME)%","upstream_cluster":"%UPSTREAM_CLUSTER%","x_forwarded_for":"%REQ(X-FORWARDED-FOR)%","request_method":"%REQ(:METHOD)%","request_path":"%REQ(X-ENVOY-ORIGINAL-PATH?:PATH)%","request_protocol":"%PROTOCOL%","tls_protocol":"%DOWNSTREAM_TLS_VERSION%","request_id":"%REQ(X-REQUEST-ID)%","sni_host":"%REQUESTED_SERVER_NAME%","apigee_dynamic_data":"%DYNAMIC_METADATA(envoy.lua)%"}'
EOF
}

install_apigee_ctl() {

cd $APIGEE_WORKSPACE
export VERSION=$(curl -s \
	    https://storage.googleapis.com/apigee-release/hybrid/apigee-hybrid-setup/current-version.txt?ignoreCache=1)

#Pinning down to previous version because 1.7 has some issues
export VERSION="1.7.3"

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
	#gcloud iam service-accounts keys create ./service-accounts/$PROJECT_ID-apigee-non-prod.json --iam-account=apigee-non-prod@$PROJECT_ID.iam.gserviceaccount.com --quiet
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

	echo "Waiting for initial 60 seconds ...."
	sleep 60

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


	kubectl patch storageclass local-shared \
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
	sed -i '/hostNetwork: false/a \ \ replicaCount: 3' overrides.yaml
	yq -i '.gcp.projectID = env(PROJECT_ID)' overrides.yaml
	yq -i '.org = env(PROJECT_ID)' overrides.yaml
	yq -i '.k8sCluster.name = "apigee-hybrid"' overrides.yaml
	yq -i '.k8sCluster.region = "us-central1-a"' overrides.yaml
	yq -i '.instanceID = "apigee-hybrid-demo"' overrides.yaml
	yq -i '.cassandra.hostNetwork = true' overrides.yaml
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
	yq e '{"logger" : {"serviceAccountPath" : env(SVC_ACCOUNT)}}'  overrides.yaml >> overrides.yaml


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

echo "Checking Apigee Containers ..."
status=$($APIGEECTL_HOME/apigeectl check-ready -f overrides/overrides.yaml 2>&1)
apigee_ready=$(echo $status | grep 'All containers are ready.')
#apigee_ready=""

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
	wait_for_apigee_ready
        ${APIGEECTL_HOME}/apigeectl apply -f overrides/overrides.yaml
	wait_for_apigee_ready

}


create_workspace
enable_services
enable_apigee_services
install_cert_manager
download_asm
create_overlay_asm
install_asm
install_apigee_ctl
setup_project_directory
setup_org_env
patch_standard_storageclass
prepare_overrides_files
enable_synchronizer
install_runtime
