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
from app.helpers.serp_client import SerpApiClient
from app.ingestion_func import IngestionFunctions

def main():
    print("[ingestion] Ingestion app is running")
    
    mode = os.getenv("MODE", "search_and_fetch")
    if mode != "search_and_fetch":
        print(f"[ingestion] unsupported mode {mode}", file=sys.stderr)
        sys.exit(2)

    msg = {
        "query": os.getenv("QUERY", "coffee"),
        "limit": int(os.getenv("LIMIT", "10")),
        "max_reviews": int(os.getenv("MAX_REVIEWS", "40")),
        "lang": os.getenv("HL", "en"),
        "country": os.getenv("GL", "ca"),
        "ll": os.getenv("LL")  # optional
    }
    ingestion_functions = IngestionFunctions(hl=msg["lang"], gl=msg["country"])
    ingestion_functions.run_search_and_fetch(msg)

if __name__ == "__main__":
    main()