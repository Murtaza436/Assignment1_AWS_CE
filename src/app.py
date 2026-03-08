"""
UniEvent - University Event Management System
CE 308/408 Cloud Computing - Assignment 1
GIKI - Cloud Architecture on AWS
"""

from flask import Flask, render_template, jsonify, request
import requests
import boto3
import json
import os
import logging
from datetime import datetime
from botocore.exceptions import ClientError

# ── App Configuration ──────────────────────────────────────────────────────────
app = Flask(__name__)
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# ── Environment Variables (set via EC2 User Data or .env) ──────────────────────
TICKETMASTER_API_KEY = os.environ.get("TICKETMASTER_API_KEY", "YOUR_API_KEY_HERE")
S3_BUCKET_NAME       = os.environ.get("S3_BUCKET_NAME", "unievent-media-bucket")
AWS_REGION           = os.environ.get("AWS_REGION", "us-east-1")

# ── AWS S3 Client ──────────────────────────────────────────────────────────────
s3_client = boto3.client("s3", region_name=AWS_REGION)


# ── Helper: Fetch Events from Ticketmaster API ─────────────────────────────────
def fetch_events_from_api():
    """
    Fetches university-relevant events from the Ticketmaster Discovery API.
    Returns a list of normalized event dicts.
    """
    url = "https://app.ticketmaster.com/discovery/v2/events.json"
    params = {
        "apikey": TICKETMASTER_API_KEY,
        "classificationName": "education,conference,seminar",
        "size": 20,
        "sort": "date,asc",
        "countryCode": "US",
    }

    try:
        response = requests.get(url, params=params, timeout=10)
        response.raise_for_status()
        data = response.json()

        raw_events = data.get("_embedded", {}).get("events", [])
        events = []

        for ev in raw_events:
            venue_info = ev.get("_embedded", {}).get("venues", [{}])[0]
            images    = ev.get("images", [])
            image_url = images[0]["url"] if images else "/static/images/default_event.png"

            events.append({
                "id":          ev.get("id"),
                "title":       ev.get("name", "Untitled Event"),
                "date":        ev.get("dates", {}).get("start", {}).get("localDate", "TBA"),
                "time":        ev.get("dates", {}).get("start", {}).get("localTime", "TBA"),
                "venue":       venue_info.get("name", "University Campus"),
                "city":        venue_info.get("city", {}).get("name", ""),
                "description": ev.get("info", ev.get("pleaseNote", "No description available.")),
                "image_url":   image_url,
                "ticket_url":  ev.get("url", "#"),
                "category":    ev.get("classifications", [{}])[0].get("segment", {}).get("name", "General"),
            })

        # Cache fetched events to S3
        _cache_events_to_s3(events)
        return events

    except requests.exceptions.RequestException as e:
        logger.error(f"API fetch failed: {e}")
        # Fall back to S3-cached events
        return _load_events_from_s3()


def _cache_events_to_s3(events: list):
    """Persist fetched events as JSON to S3 for fault-tolerance."""
    try:
        payload = json.dumps({"cached_at": datetime.utcnow().isoformat(), "events": events})
        s3_client.put_object(
            Bucket=S3_BUCKET_NAME,
            Key="cache/events.json",
            Body=payload,
            ContentType="application/json",
        )
        logger.info("Events cached to S3 successfully.")
    except ClientError as e:
        logger.warning(f"S3 cache write failed: {e}")


def _load_events_from_s3() -> list:
    """Load previously cached events from S3 when the live API is unavailable."""
    try:
        obj = s3_client.get_object(Bucket=S3_BUCKET_NAME, Key="cache/events.json")
        data = json.loads(obj["Body"].read())
        logger.info("Loaded events from S3 cache.")
        return data.get("events", [])
    except ClientError as e:
        logger.error(f"S3 cache read failed: {e}")
        return _get_mock_events()


def _get_mock_events() -> list:
    """Static fallback events used during local development."""
    return [
        {
            "id": "mock_001",
            "title": "Annual Tech Fest 2025",
            "date": "2025-09-15",
            "time": "10:00:00",
            "venue": "GIKI Main Auditorium",
            "city": "Topi",
            "description": "Join us for the biggest tech festival of the year featuring workshops, competitions, and keynote speakers from top tech companies.",
            "image_url": "/static/images/default_event.png",
            "ticket_url": "#",
            "category": "Technology",
        },
        {
            "id": "mock_002",
            "title": "Society Recruitment Drive",
            "date": "2025-09-20",
            "time": "09:00:00",
            "venue": "Student Center",
            "city": "Topi",
            "description": "Explore over 30 student societies and clubs. Find your community and sign up for the activities that excite you most.",
            "image_url": "/static/images/default_event.png",
            "ticket_url": "#",
            "category": "Campus Life",
        },
        {
            "id": "mock_003",
            "title": "Cloud Computing Workshop",
            "date": "2025-09-25",
            "time": "14:00:00",
            "venue": "CS Department Lab",
            "city": "Topi",
            "description": "Hands-on AWS workshop covering EC2, S3, VPC, IAM, and Elastic Load Balancing. Perfect for CE 308/408 students.",
            "image_url": "/static/images/default_event.png",
            "ticket_url": "#",
            "category": "Academic",
        },
    ]


# ── Upload Media to S3 ─────────────────────────────────────────────────────────
def upload_media_to_s3(file_obj, filename: str) -> str:
    """
    Upload an event poster / image to S3.
    Returns the public URL of the uploaded object.
    """
    key = f"media/{datetime.utcnow().strftime('%Y%m%d%H%M%S')}_{filename}"
    try:
        s3_client.upload_fileobj(
            file_obj,
            S3_BUCKET_NAME,
            key,
            ExtraArgs={"ContentType": "image/jpeg"},
        )
        url = f"https://{S3_BUCKET_NAME}.s3.{AWS_REGION}.amazonaws.com/{key}"
        logger.info(f"Media uploaded to S3: {url}")
        return url
    except ClientError as e:
        logger.error(f"S3 upload failed: {e}")
        return ""


# ── Routes ─────────────────────────────────────────────────────────────────────
@app.route("/")
def index():
    events = fetch_events_from_api()
    return render_template("index.html", events=events)


@app.route("/api/events")
def api_events():
    """JSON endpoint — consumed by the front-end JS for dynamic refresh."""
    events = fetch_events_from_api()
    return jsonify({"status": "success", "count": len(events), "events": events})


@app.route("/api/upload", methods=["POST"])
def upload_poster():
    """Accept a multipart file upload and store it in S3."""
    if "file" not in request.files:
        return jsonify({"error": "No file provided"}), 400

    f    = request.files["file"]
    url  = upload_media_to_s3(f.stream, f.filename)

    if url:
        return jsonify({"status": "success", "url": url})
    return jsonify({"error": "Upload failed"}), 500


@app.route("/health")
def health():
    """ELB / ALB health-check endpoint."""
    return jsonify({"status": "healthy", "timestamp": datetime.utcnow().isoformat()}), 200


# ── Entry Point ────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=False)
