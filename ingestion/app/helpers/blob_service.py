import json
import os
import sys
import time
from datetime import datetime, timezone

from azure.identity import DefaultAzureCredential, ManagedIdentityCredential
from azure.storage.blob import BlobServiceClient
from azure.servicebus import ServiceBusClient, ServiceBusMessage


class BlobServiceHelper:

    def __init__(self, storage_account_url: str, container_name: str):
        self.storage_account_url = self.env(storage_account_url)
        self.container_name = self.env(container_name)

    # Get Environment Variables
    def env(self, name: str) -> str:
        value = os.getenv(name)
        if not value:
            print(f"[blob helper] Missing env var: {name}", file=sys.stderr)
            raise ValueError(f"Missing env var: {name}")
        return value

    def build_blob_client(self, credential):
        try:
            url = f"https://{self.storage_account_url}.blob.core.windows.net"
            svc = BlobServiceClient(account_url=url, credential=credential)
            return svc.get_container_client(self.container_name)
        except Exception as e:
            print(f"[blob helper] Error building blob client: {e}", file=sys.stderr)
            raise e
        
    def write_hello_blob_test(self, container_client, place_id: str):
        ts = datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S")
        blob_name = f"hello/{place_id}/hello-{ts}.txt"
        data = f"hello from ingestion at {ts}, place_id={place_id}\n".encode("utf-8")
        try:
            container_client.upload_blob(name=blob_name, data=data, overwrite=True)
            print(f"[blob helper] Wrote test blob: {blob_name}")
            return blob_name
        except Exception as e:
            print(f"[blob helper] Error writing test blob: {e}", file=sys.stderr)
            raise e
        
    def write_blob_file(self, container_client, blob_name: str, data: bytes):
        try:
            container_client.upload_blob(name=blob_name, data=data, overwrite=True)
            print(f"[blob helper] Wrote blob file: {blob_name}")
            return blob_name
        except Exception as e:
            print(f"[blob helper] Error writing blob file: {e}", file=sys.stderr)
            raise e