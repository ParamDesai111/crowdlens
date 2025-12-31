import os
import sys
import json
from datetime import datetime, timezone

from azure.identity import DefaultAzureCredential, ManagedIdentityCredential
from azure.servicebus import ServiceBusMessage
from io import BytesIO

from app.helpers.blob_service import BlobServiceHelper
from app.helpers.service_bus import ServiceBusHelper
from app.helpers.serp_client import SerpApiClient


class IngestionFunctions:

    def __init__(self, hl: str = "en", gl: str = "ca"):
        self.credential = ManagedIdentityCredential(client_id=os.getenv("AZURE_CLIENT_ID")) if os.getenv("AZURE_CLIENT_ID") else DefaultAzureCredential()

        # Initialize helpers
        self.blob_helper = BlobServiceHelper(
            storage_account_url="BLOB_ACCOUNT",
            container_name="BLOB_CONTAINER"
        )

        self.service_bus_helper = ServiceBusHelper(
            service_bus_namespace="SB_NAMESPACE",
            queue_name="SB_QUEUE_PROCESS"
        )
        
        api_key = os.getenv("SERPAPI_KEY", "")
        if not api_key:
            print("[ingestion func] Missing SERP_API_KEY environment variable", file=sys.stderr)
            raise ValueError("Missing SERP_API_KEY environment variable")

        self.serp = SerpApiClient(
            api_key=api_key,
            hl=hl,
            gl=gl
        )

    def write_json(self, blob_name, obj):
        data = json.dumps(obj, ensure_ascii=False).encode("utf-8")

        container_client = self.blob_helper.build_blob_client(self.credential)
        
        container_client.upload_blob(
            name=blob_name,
            data=BytesIO(data),
            overwrite=True
        )

        return blob_name
    
    def slugify(self, text: str) -> str:
        return "".join(c.lower() if c.isalnum() else "-" for c in text).strip("-")

    def run_search_and_fetch(self, msg: dict):
        query = msg.get("query")
        limit = int(msg.get("limit", 10))
        ll = msg.get("ll")
        max_reviews = int(msg.get("max_reviews", 40))

        places = self.serp.get_place(query=query, ll=ll, limit=limit) or []

        day = datetime.now(timezone.utc).strftime("%Y-%m-%d-%H%M%S")
        search_key = f"search/{day}/{self.slugify(query)}/search_results.json"
        blob_name = self.write_json(search_key, {"query": query, "results": places})
        print(f"[ingestion func] Wrote search results to blob: {blob_name} with {len(places)} places")

        sb_client, sb_sender = self.service_bus_helper.build_service_bus_sender(self.credential)
        try:
            for idx, place in enumerate(places, 1):
                pid = place.get("place_id")
                print(f"[ingestion func] Processing place {idx}/{len(places)} (place_id: {pid})")
                if not pid:
                    print("[ingestion func] Skipping place without place_id")
                    continue

                base = f"review/{day}/{pid}/"
                meta_blob = base + "metadata.json"
                self.write_json(meta_blob, place)

                reviews = self.serp.fetch_reviews(place_id=pid, max_reviews=max_reviews)
                print(f"[ingestion func] Fetched {len(reviews)} reviews for place_id: {pid}")

                blob_paths = [meta_blob]
                chunk = 200
                for i in range(0, len(reviews), chunk):
                    part = reviews[i:i+chunk]
                    path = base + f"reviews-{i//chunk + 1:04d}.json"
                    self.write_json(path, part)
                    blob_paths.append(path)

                print(f"[ingestion func] Fetched and wrote {len(reviews)} reviews for place_id: {pid} in {len(blob_paths)} blobs")

                payload = {
                    "place_id": pid,
                    "place_name": place.get("name"),
                    "blob_paths": blob_paths,
                    "fetch_ts": int(datetime.now(timezone.utc).timestamp()),
                    "review_count": len(reviews),
                    "source": "serpapi-google-maps",
                    "query": query,
                    "rank": idx,
                }

                try:
                    sb_sender.send_messages(ServiceBusMessage(json.dumps(payload)))
                    print(f"[ingestion func] Sent Service Bus message for place_id: {pid}")
                except Exception as send_err:
                    print(f"[ingestion func] Error sending service bus message for place_id: {pid}: {send_err}", file=sys.stderr)
        finally:
            try:
                sb_sender.close()
                sb_client.close()
                print("[ingestion func] Closed service bus client")
            except Exception as close_err:
                print(f"[ingestion func] Error closing service bus client: {close_err}", file=sys.stderr)
