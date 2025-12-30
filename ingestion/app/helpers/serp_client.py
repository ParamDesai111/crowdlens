import os
import time
import random
import requests
from typing import List, Dict, Optional


class SerpApiClient:
    
    def __init__(self, api_key: str, hl: str, gl: str):
        self.api_key = api_key # Api key of SerpApi
        self.hl = hl # Language code
        self.gl = gl # Country code
        self.base_url = "https://serpapi.com/search" # Base URL for SerpApi


    def _call(self, params):
        params.update({
            "api_key": self.api_key
        })

        # Add retry logic for transient errors
        max_retries = 3
        for attempt in range(max_retries):
            try:
                response = requests.get(self.base_url, params=params, timeout=30)
                response.raise_for_status()
                return response.json()
            except requests.RequestException as e:
                print(f"[serp api client] Error calling SerpApi (attempt {attempt + 1}): {e}")
                if attempt < max_retries - 1:
                    sleep_time = (2 ** attempt) + random.uniform(0, 1)
                    time.sleep(sleep_time)
                else:
                    raise e
    
    def get_place(self, query: str, ll: Optional[str] = None, limit: int = 10) -> Optional[List[Dict]]:
        # ll = "latitude,longitude"

        params = {
            "engine": "google_maps",
            "q": query,
            "hl": self.hl,
            "gl": self.gl
        }

        # add ll if provided
        if ll:
            params["ll"] = ll
        
        data = self._call(params)

        # Pick the first candidate
        results = data.get("local_results", []) or data.get("place_results", [])

        if not results:
            return None
        
        norm = []
        
        for r in results[:limit]:
            norm.append({
                "raw": r,
                "place_id": r.get("place_id"),
                "data_id": r.get("data_id"),

            })

        return norm
    
    def fetch_reviews(self, place_id: str, max_reviews: int = 40, sort: str = "qualityScore"):
        """Fetch reviews for a given place_id from SerpApi.
        Sort types
        qualityScore - the most relevant reviews (default).
        newestFirst - the most recent reviews.
        ratingHigh - the highest rating reviews.
        ratingLow - the lowest rating reviews.
        """
        collected_reviews = []
        page_token = None
    
        while len(collected_reviews) < max_reviews:
            params = {
                "engine": "google_maps_reviews",
                "place_id": place_id,
                "hl": self.hl,
                "gl": self.gl,
                "sort_by": sort
            }

            if page_token:
                params["next_page_token"] = page_token
            
            data = self._call(params)
            reviews = data.get("reviews", [])
            collected_reviews.extend(reviews)
            page_token = data.get("next_page_token")

            if not page_token or not reviews:
                break

        return collected_reviews[:max_reviews]