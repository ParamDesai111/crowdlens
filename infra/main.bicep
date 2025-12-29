@description('Azure region')
param location string = 'eastus'

@description('Name prefix for resource names')
param namePrefix string = 'crowdlensdev'

@description('Postgres admin user')
param pgAdminUser string = 'pgadmin'

@secure()
@description('Postgres admin password')
param pgAdminPwd string

@description('Create Container Apps for services')
param createApps bool = true

@description('Backend image - set to ACR login server image like acrcrowdlensdev.azurecr.io/backend:dev')
param backendImage string = ''

@description('Ingestion image')
param ingestionImage string = ''

@description('ML worker image')
param mlImage string = ''

@description('Key Vault secret name for the Postgres URL')
param kvSecretPostgresName string = 'POSTGRES-URL'

@description('Key Vault secret name for the JWT secret')
param kvSecretJwtName string = 'JWT-SECRET'

@description('Key Vault secret name for the SerpAPI key')
param kvSecretSerpapiName string = 'SERPAPI-KEY'

@description('Minimum and maximum replicas for backend')
param backendMinReplicas int = 1
param backendMaxReplicas int = 2

@description('Minimum and maximum replicas for workers')
param workerMinReplicas int = 0
param workerMaxReplicas int = 5

// ---------- Core resources ----------

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: 'acr${namePrefix}'
  location: location
  sku: { name: 'Basic' }
  properties: {}
}

resource logws 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: 'law-${namePrefix}'
  location: location
  properties: {}
}

resource cae 'Microsoft.App/managedEnvironments@2023-05-01' = {
  name: 'cae-${namePrefix}'
  location: location
  properties: {
    appLogsConfiguration: {
      logAnalyticsConfiguration: {
        customerId: logws.properties.customerId
        sharedKey: listKeys(logws.id, '2022-10-01').primarySharedKey
      }
    }
  }
}

resource sa 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: 'sto${uniqueString(resourceGroup().id, namePrefix)}'
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
}

resource blobContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  name: '${sa.name}/default/raw'
  properties: {
    publicAccess: 'None'
  }
}

resource sb 'Microsoft.ServiceBus/namespaces@2022-10-01-preview' = {
  name: 'sb-${namePrefix}'
  location: location
  sku: {
    name: 'Basic'
    tier: 'Basic'
  }
}

resource qIngest 'Microsoft.ServiceBus/namespaces/queues@2022-10-01-preview' = {
  name: '${sb.name}/ingest'
  properties: {}
}

resource qProcess 'Microsoft.ServiceBus/namespaces/queues@2022-10-01-preview' = {
  name: '${sb.name}/process'
  properties: {}
}

resource pg 'Microsoft.DBforPostgreSQL/flexibleServers@2022-12-01' = {
  name: 'pg-${namePrefix}-dev'
  location: location
  sku: {
    name: 'B1ms'
    tier: 'Burstable'
  }
  properties: {
    version: '16'
    administratorLogin: pgAdminUser
    administratorLoginPassword: pgAdminPwd
    storage: {
      storageSizeGB: 32
    }
    network: {
      publicNetworkAccess: 'Enabled'
    }
  }
}

resource kv 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: 'kv-${namePrefix}-${uniqueString(resourceGroup().id)}'
  location: location
  properties: {
    tenantId: subscription().tenantId
    sku: {
      name: 'standard'
      family: 'A'
    }
    enablePurgeProtection: false
    accessPolicies: []
  }
}

resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'uami-${namePrefix}-apps'
  location: location
}

resource kvAccess 'Microsoft.KeyVault/vaults/accessPolicies@2023-07-01' = {
  name: '${kv.name}/add'
  properties: {
    accessPolicies: [
      {
        tenantId: subscription().tenantId
        objectId: uami.properties.principalId
        permissions: {
          secrets: [
            'get'
            'list'
          ]
        }
      }
    ]
  }
}

// ---------- Optional Container Apps ----------

var registryServer = acr.properties.loginServer

// Common registry credentials using the user assigned identity
var registriesBlock = [
  {
    server: registryServer
    identity: uami.id
  }
]

@description('Backend Container App')
resource backendApp 'Microsoft.App/containerApps@2023-05-01' = if (createApps && backendImage != '') {
  name: 'backend'
  location: location
  properties: {
    managedEnvironmentId: cae.id
    configuration: {
      registries: registriesBlock
      ingress: {
        external: true
        targetPort: 8080
      }
      secrets: [
        {
          name: 'postgres-url'
          keyVaultUrl: 'https://${kv.name}.vault.azure.net/secrets/${kvSecretPostgresName}'
          identity: uami.id
        }
        {
          name: 'jwt-secret'
          keyVaultUrl: 'https://${kv.name}.vault.azure.net/secrets/${kvSecretJwtName}'
          identity: uami.id
        }
      ]
      activeRevisionsMode: 'Single'
    }
    template: {
      containers: [
        {
          name: 'backend'
          image: backendImage
          env: [
            { name: 'KV_NAME', value: kv.name }
            { name: 'SB_NAMESPACE', value: sb.name }
            { name: 'SB_QUEUE_INGEST', value: 'ingest' }
            { name: 'SB_QUEUE_PROCESS', value: 'process' }
            { name: 'POSTGRES_URL', secretRef: 'postgres-url' }
            { name: 'JWT_SECRET', secretRef: 'jwt-secret' }
          ]
          resources: {
            cpu: 0.5
            memory: '1Gi'
          }
        }
      ]
      scale: {
        minReplicas: backendMinReplicas
        maxReplicas: backendMaxReplicas
      }
    }
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${uami.id}': {}
    }
  }
}

@description('Ingestion Container App')
resource ingestionApp 'Microsoft.App/containerApps@2023-05-01' = if (createApps && ingestionImage != '') {
  name: 'ingestion'
  location: location
  properties: {
    managedEnvironmentId: cae.id
    configuration: {
      registries: registriesBlock
      ingress: {
        external: false
        targetPort: 8080
      }
      secrets: [
        {
          name: 'postgres-url'
          keyVaultUrl: 'https://${kv.name}.vault.azure.net/secrets/${kvSecretPostgresName}'
          identity: uami.id
        }
        {
          name: 'serpapi-key'
          keyVaultUrl: 'https://${kv.name}.vault.azure.net/secrets/${kvSecretSerpapiName}'
          identity: uami.id
        }
      ]
      activeRevisionsMode: 'Single'
    }
    template: {
      containers: [
        {
          name: 'ingestion'
          image: ingestionImage
          env: [
            { name: 'KV_NAME', value: kv.name }
            { name: 'SB_NAMESPACE', value: sb.name }
            { name: 'SB_QUEUE_INGEST', value: 'ingest' }
            { name: 'BLOB_ACCOUNT', value: sa.name }
            { name: 'BLOB_CONTAINER', value: 'raw' }
            { name: 'POSTGRES_URL', secretRef: 'postgres-url' }
            { name: 'SERPAPI_KEY', secretRef: 'serpapi-key' }
          ]
          resources: {
            cpu: 0.5
            memory: '1Gi'
          }
        }
      ]
      scale: {
        minReplicas: workerMinReplicas
        maxReplicas: workerMaxReplicas
      }
    }
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${uami.id}': {}
    }
  }
}

@description('ML Worker Container App')
resource mlApp 'Microsoft.App/containerApps@2023-05-01' = if (createApps && mlImage != '') {
  name: 'ml-worker'
  location: location
  properties: {
    managedEnvironmentId: cae.id
    configuration: {
      registries: registriesBlock
      ingress: {
        external: false
        targetPort: 8080
      }
      secrets: [
        {
          name: 'postgres-url'
          keyVaultUrl: 'https://${kv.name}.vault.azure.net/secrets/${kvSecretPostgresName}'
          identity: uami.id
        }
      ]
      activeRevisionsMode: 'Single'
    }
    template: {
      containers: [
        {
          name: 'ml-worker'
          image: mlImage
          env: [
            { name: 'KV_NAME', value: kv.name }
            { name: 'SB_NAMESPACE', value: sb.name }
            { name: 'SB_QUEUE_PROCESS', value: 'process' }
            { name: 'BLOB_ACCOUNT', value: sa.name }
            { name: 'BLOB_CONTAINER', value: 'raw' }
            { name: 'POSTGRES_URL', secretRef: 'postgres-url' }
          ]
          resources: {
            cpu: 0.5
            memory: '1Gi'
          }
        }
      ]
      scale: {
        minReplicas: workerMinReplicas
        maxReplicas: workerMaxReplicas
      }
    }
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${uami.id}': {}
    }
  }
}

// ---------- Outputs ----------

output acrLoginServer string = acr.properties.loginServer
output logAnalyticsName string = logws.name
output containerAppsEnvName string = cae.name
output storageAccountName string = sa.name
output serviceBusNamespace string = sb.name
output postgresFqdn string = pg.properties.fullyQualifiedDomainName
output keyVaultName string = kv.name
output userAssignedIdentityId string = uami.id

// Executable
// RG="rg-crowdlens-dev"
// LOCATION="eastus"
// PG_ADMIN_PWD="$(openssl rand -base64 20)"

// az group create -n $RG -l $LOCATION

// az deployment group create \
//   -g $RG \
//   -f infra/main.bicep \
//   -p pgAdminPwd="$PG_ADMIN_PWD" \
//      backendImage="acrcrowdlensdev.azurecr.io/backend:dev" \
//      ingestionImage="acrcrowdlensdev.azurecr.io/ingestion:dev" \
//      mlImage="acrcrowdlensdev.azurecr.io/ml-worker:dev"
