#!/usr/bin/env bash
set -euo pipefail

# Config
LOCATION="eastus"
RG="rg-crowdlens-dev"
ACR="acrcrowdlensdev$RANDOM"
LOGWS="law-crowdlens-dev"
CAE="cae-crowdlens-dev"
SB="sb-crowdlens-dev"
STO="stocrowdlens$RANDOM"
KV="kv-crowdlens-$RANDOM"
PG="pg-crowdlens-dev"
PG_DB="crowdlens"
PG_ADMIN_USER="pgadmin"
PG_ADMIN_PWD="$(openssl rand -base64 20)"

echo "[+] Resource group"
az group create -n "$RG" -l "$LOCATION"

echo "[+] ACR"
az acr create -g "$RG" -n "$ACR" --sku Basic
ACR_LOGIN="${ACR}.azurecr.io"

echo "[+] Log Analytics workspace"
az monitor log-analytics workspace create -g "$RG" -n "$LOGWS" -l "$LOCATION"
LOGWS_ID=$(az monitor log-analytics workspace show -g "$RG" -n "$LOGWS" --query id -o tsv)
LOGWS_KEY=$(az monitor log-analytics workspace get-shared-keys -g "$RG" -n "$LOGWS" --query primarySharedKey -o tsv)

echo "[+] Container Apps extension and environment"
az extension add -n containerapp --upgrade
az containerapp env create -g "$RG" -n "$CAE" -l "$LOCATION" \
  --logs-workspace-id "$LOGWS_ID" \
  --logs-workspace-key "$LOGWS_KEY"

echo "[+] Storage account + raw container"
az storage account create -g "$RG" -n "$STO" -l "$LOCATION" --sku Standard_LRS
az storage container create --account-name "$STO" --name raw --auth-mode login

echo "[+] Service Bus namespace + queues"
az servicebus namespace create -g "$RG" -n "$SB" -l "$LOCATION" --sku Basic
az servicebus queue create -g "$RG" --namespace-name "$SB" --name ingest
az servicebus queue create -g "$RG" --namespace-name "$SB" --name process

echo "[+] Postgres Flexible Server"
az postgres flexible-server create -g "$RG" -n "$PG" -l "$LOCATION" \
  --version 16 --sku-name B1ms --storage-size 32 --tier Burstable \
  --admin-user "$PG_ADMIN_USER" --admin-password "$PG_ADMIN_PWD" \
  --public-access 0.0.0.0-0.0.0.0

MYIP=$(curl -s ifconfig.me || echo "0.0.0.0")
az postgres flexible-server firewall-rule create -g "$RG" -n "$PG" -r myip --start-ip-address "$MYIP" --end-ip-address "$MYIP"
PG_FQDN=$(az postgres flexible-server show -g "$RG" -n "$PG" --query fullyQualifiedDomainName -o tsv)

echo "[+] Key Vault"
az keyvault create -g "$RG" -n "$KV" -l "$LOCATION"

echo "[+] Create Key Vault secrets placeholders"
POSTGRES_URL="postgres://${PG_ADMIN_USER}:${PG_ADMIN_PWD}@${PG_FQDN}:5432/${PG_DB}?sslmode=require"
JWT_SECRET="$(openssl rand -hex 32)"
SERPAPI_KEY="set-this-later"

az keyvault secret set --vault-name "$KV" --name POSTGRES-URL --value "$POSTGRES_URL"
az keyvault secret set --vault-name "$KV" --name JWT-SECRET --value "$JWT_SECRET"
az keyvault secret set --vault-name "$KV" --name SERPAPI-KEY --value "$SERPAPI_KEY"

echo "[+] User assigned managed identity for apps"
UA_MI="uami-crowdlens-apps"
az identity create -g "$RG" -n "$UA_MI" -l "$LOCATION"
UA_MI_ID=$(az identity show -g "$RG" -n "$UA_MI" --query id -o tsv)
UA_MI_PRINCIPAL_ID=$(az identity show -g "$RG" -n "$UA_MI" --query principalId -o tsv)

echo "[+] Grant Key Vault get,list to the identity"
az keyvault set-policy -n "$KV" --object-id "$UA_MI_PRINCIPAL_ID" --secret-permissions get list

echo "[+] Create Container Apps with KV secret refs"
BACKEND_IMG="${ACR_LOGIN}/backend:dev"
INGEST_IMG="${ACR_LOGIN}/ingestion:dev"
ML_IMG="${ACR_LOGIN}/ml-worker:dev"

# backend
az containerapp create -g "$RG" -n backend \
  --environment "$CAE" -l "$LOCATION" \
  --image "$BACKEND_IMG" \
  --ingress external --target-port 8080 \
  --registry-server "$ACR_LOGIN" \
  --min-replicas 1 --max-replicas 2 \
  --user-assigned "$UA_MI_ID" \
  --secrets \
    postgres-url="keyvaultref:https://$KV.vault.azure.net/secrets/POSTGRES-URL,identityref:$UA_MI_ID" \
    jwt-secret="keyvaultref:https://$KV.vault.azure.net/secrets/JWT-SECRET,identityref:$UA_MI_ID" \
  --env-vars \
    KV_NAME="$KV" \
    SB_NAMESPACE="$SB" \
    SB_QUEUE_INGEST="ingest" \
    SB_QUEUE_PROCESS="process" \
    POSTGRES_URL="secretref:postgres-url" \
    JWT_SECRET="secretref:jwt-secret"

# ingestion
az containerapp create -g "$RG" -n ingestion \
  --environment "$CAE" -l "$LOCATION" \
  --image "$INGEST_IMG" \
  --ingress internal \
  --registry-server "$ACR_LOGIN" \
  --min-replicas 0 --max-replicas 5 \
  --user-assigned "$UA_MI_ID" \
  --secrets \
    postgres-url="keyvaultref:https://$KV.vault.azure.net/secrets/POSTGRES-URL,identityref:$UA_MI_ID" \
    serpapi-key="keyvaultref:https://$KV.vault.azure.net/secrets/SERPAPI-KEY,identityref:$UA_MI_ID" \
  --env-vars \
    KV_NAME="$KV" \
    SB_NAMESPACE="$SB" \
    SB_QUEUE_INGEST="ingest" \
    BLOB_ACCOUNT="$STO" \
    BLOB_CONTAINER="raw" \
    POSTGRES_URL="secretref:postgres-url" \
    SERPAPI_KEY="secretref:serpapi-key"

# ml-worker
az containerapp create -g "$RG" -n ml-worker \
  --environment "$CAE" -l "$LOCATION" \
  --image "$ML_IMG" \
  --ingress internal \
  --registry-server "$ACR_LOGIN" \
  --min-replicas 0 --max-replicas 5 \
  --user-assigned "$UA_MI_ID" \
  --secrets \
    postgres-url="keyvaultref:https://$KV.vault.azure.net/secrets/POSTGRES-URL,identityref:$UA_MI_ID" \
  --env-vars \
    KV_NAME="$KV" \
    SB_NAMESPACE="$SB" \
    SB_QUEUE_PROCESS="process" \
    BLOB_ACCOUNT="$STO" \
    BLOB_CONTAINER="raw" \
    POSTGRES_URL="secretref:postgres-url"

echo "[+] Done"
echo "ACR login server: $ACR_LOGIN"
echo "Key Vault: $KV"
echo "Postgres FQDN: $PG_FQDN"
