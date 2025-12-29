import json
import os
import sys
import time
from datetime import datetime, timezone

from azure.identity import DefaultAzureCredential, ManagedIdentityCredential
from azure.storage.blob import BlobServiceClient
from azure.servicebus import ServiceBusClient, ServiceBusMessage


class ServiceBusHelper:
    def __init__(self, service_bus_namespace: str, queue_name: str):
        self.service_bus_namespace = self.env(service_bus_namespace)
        self.queue_name = self.env(queue_name)

    # Get Environment Variables
    def env(self, name: str) -> str:
        value = os.getenv(name)
        if not value:
            print(f"[service bus helper] Missing env var: {name}", file=sys.stderr)
            raise ValueError(f"Missing env var: {name}")
        return value
    
    def build_service_bus_sender(self, credential):
        try:
            fully_qualified_namespace = f"{self.service_bus_namespace}.servicebus.windows.net"
            client = ServiceBusClient(
                fully_qualified_namespace=fully_qualified_namespace,
                credential=credential
            )
            sender = client.get_queue_sender(queue_name=self.queue_name)
            return client, sender
        except Exception as e:
            print(f"[service bus helper] Error building service bus sender: {e}", file=sys.stderr)
            raise e
    
    def send_process_blob_message(self, client, sender, place_id: str, blob_path: str):
        payload = {
            "place_id": place_id,
            "blob_paths": [blob_path],
            "fetch_ts": int(time.time()),
            "source": "stub-ingestion"
        }

        try:
            msg = ServiceBusMessage(json.dumps(payload))
            with sender:
                sender.send_messages(msg)
            print(f"[service bus helper] Sent message for blob: {blob_path}")
            return payload
        except Exception as e:
            print(f"[service bus helper] Error sending service bus message: {e}", file=sys.stderr)
            raise e
    
    def close_service_bus_client(self, client):
        try:
            client.close()
            print(f"[service bus helper] Closed service bus client")
        except Exception as e:
            print(f"[service bus helper] Error closing service bus client: {e}", file=sys.stderr)
            raise e