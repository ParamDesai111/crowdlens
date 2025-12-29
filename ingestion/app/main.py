import json
import os
import sys
import time
from datetime import datetime, timezone

from azure.identity import DefaultAzureCredential, ManagedIdentityCredential
from azure.storage.blob import BlobServiceClient
from azure.servicebus import ServiceBusClient, ServiceBusMessage

# Get helpers
from app.helpers.blob_service import BlobServiceHelper
from app.helpers.service_bus import ServiceBusHelper

def main():
    print("[ingestion] Ingestion app is running")
    
    # Inputs for the stub
    place_id = os.getenv("PLACE_ID", "demo-place")

    # credential = DefaultAzureCredential()
    credential = ManagedIdentityCredential(client_id=os.getenv("AZURE_CLIENT_ID")) if os.getenv("AZURE_CLIENT_ID") else DefaultAzureCredential()

    # Blob Service Operations
    blob_helper = BlobServiceHelper(
        storage_account_url="BLOB_ACCOUNT",
        container_name="BLOB_CONTAINER"
    )
    container_client = blob_helper.build_blob_client(credential)
    blob_name = blob_helper.write_hello_blob_test(container_client, place_id)

    # Service Bus Operations
    service_bus_helper = ServiceBusHelper(
        service_bus_namespace="SB_NAMESPACE",
        queue_name="SB_QUEUE_PROCESS"
    )
    sb_client, sb_sender = service_bus_helper.build_service_bus_sender(credential)
    
    try:

        message_payload = service_bus_helper.send_process_blob_message(
            sb_client,
            sb_sender,
            place_id,
            blob_name
        )
        print(f"[ingestion] Sent Service Bus message payload: {json.dumps(message_payload)}")
    finally:
        service_bus_helper.close_service_bus_client(sb_client)

    print("[ingestion] Ingestion app completed successfully")


if __name__ == "__main__":
    main()