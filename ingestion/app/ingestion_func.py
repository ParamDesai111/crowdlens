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
        
        api_key = os.getenv("SERP_API_KEY", "")
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
        ll = msg.get("ll") # Optional latitude,longitude
        max_reviews = int(msg.get("max_reviews", 40))
        sb_client, sb_sender = self.service_bus_helper.build_service_bus_sender(self.credential)

        # Search top places
        places = self.serp.get_place(query=query, ll=ll, limit=limit)

        # Write search results to blob
        day = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        search_key = f"search/{self.slugify(query)}/{day}/search_results.json"

        blob_name = self.write_json(search_key, {"query": query, "results": places})
        print(f"[ingestion func] Wrote search results to blob: {blob_name} and {search_key} with {len(places) if places else 0} places")

        # Loop each place to get reviews
        for idx, place in enumerate(places, 1):
            pid = place.get("place_id")
            if not pid:
                print(f"[ingestion func] Skipping place without place_id: {place}")
                continue

            base = f"raw/{pid}/{day}/"
            meta_blob = base + "metadata.json"
            self.write_json(meta_blob, place)

            # Now get reviews in chunks
            reviews = self.serp.fetch_reviews(place_id=pid, max_reviews=max_reviews)
            blob_paths = [meta_blob]
            chunk = 200

            for i in range(0, len(reviews), chunk):
                part = reviews[i:i+chunk]
                path = base + f"reviews-{i//chunk + 1:04d}.json"
                self.write_json(path, part)
                blob_paths.append(path)

            print(f"[ingestion func] Fetched and wrote {len(reviews)} reviews for place_id: {pid} in {len(blob_paths)} blobs")

            # Send message to Service Bus for processing
            payload = {
                "place_id": pid,
                "place_name": place.get("name"),
                "blob_paths": blob_paths,
                "fetch_ts": int(datetime.now(timezone.utc).timestamp()),
                "review_count": len(reviews),
                "source": "serpapi-google-maps",
                "query": query,
                "rank": idx
            }
            try:
                msg = ServiceBusMessage(json.dumps(payload))
                with sb_sender:
                    sb_sender.send_messages(msg)
                print(f"[ingestion func] Sent Service Bus message for place_id: {pid} with payload: {json.dumps(payload)}")
            except Exception as e:
                print(f"[ingestion func] Error sending service bus message for place_id: {pid}: {e}", file=sys.stderr)

        sb_client.close()
        print(f"[service bus helper] Error closing service bus client: {e}", file=sys.stderr)