import urllib.request
import urllib.error
import json
import http.cookiejar

BASE = "http://127.0.0.1:8000"

def request(path, method="GET", data=None, token=None, cookies=None):
    url = f"{BASE}{path}"
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if cookies:
        headers["Cookie"] = cookies

    encoded_data = json.dumps(data).encode("utf-8") if data else None
    req = urllib.request.Request(url, data=encoded_data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=5) as res:
            res_body = res.read().decode("utf-8")
            cookie_header = res.headers.get("Set-Cookie")
            return res.status, json.loads(res_body) if res_body else {}, cookie_header
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8")
        try:
            parsed = json.loads(body)
        except Exception:
            parsed = {"detail": body}
        return e.code, parsed, None

def run_tests():
    print("=== TEST 1: Unauthenticated access to protected endpoints ===")
    status, body, _ = request("/users")
    print(f"GET /users without token -> Status {status} (Expected 401)")
    assert status == 401, f"Expected 401, got {status}"

    status, body, _ = request("/matches")
    print(f"GET /matches without token -> Status {status} (Expected 401)")
    assert status == 401, f"Expected 401, got {status}"

    print("\n=== TEST 2: Admin Login & Role Permission ===")
    status, body, cookie = request("/auth/login", method="POST", data={"email": "admin@freshlink.org", "password": "DemoPass123!"})
    print(f"POST /auth/login as admin -> Status {status}, User: {body['user']['email']}, Role: {body['user']['role']}")
    assert status == 200
    admin_token = body["access_token"]
    assert "access_token=" in cookie or "access_token" in cookie

    # Test /auth/me with cookie
    status, me, _ = request("/auth/me", cookies=cookie.split(";")[0])
    print(f"GET /auth/me via Cookie -> Status {status}, Role: {me.get('role')}")
    assert status == 200 and me["role"] == "admin"

    # Admin access /users (strictly no password_hash)
    status, users, _ = request("/users", token=admin_token)
    print(f"GET /users as admin -> Status {status}, Total users: {len(users)}")
    assert status == 200 and len(users) >= 10
    for u in users:
        assert "password_hash" not in u, "CRITICAL: password_hash leaked in /users!"
    print("Checked all users: password_hash is strictly NOT returned.")

    print("\n=== TEST 3: Donor Login & Donor-Only Permissions ===")
    status, body, donor_cookie = request("/auth/login", method="POST", data={"email": "hostel.a@college.edu", "password": "DemoPass123!"})
    print(f"POST /auth/login as donor -> Status {status}, Role: {body['user']['role']}")
    assert status == 200
    donor_token = body["access_token"]

    # Donor trying admin endpoint /users -> MUST be 403 Forbidden
    status, err, _ = request("/users", token=donor_token)
    print(f"Donor accessing /users -> Status {status} (Expected 403)")
    assert status == 403

    # Donor creating food listing (pickup_code returned to creator)
    import datetime
    now = datetime.datetime.now(datetime.timezone.utc)
    prep = (now - datetime.timedelta(hours=1)).isoformat()
    exp = (now + datetime.timedelta(hours=4)).isoformat()

    listing_payload = {
        "category_id": 1,
        "title": "Fresh Kadai Paneer & Naan",
        "description": "Hot buffet trays",
        "quantity_kg": 7.5,
        "servings": 25,
        "prepared_at": prep,
        "expires_at": exp,
        "is_veg": True,
        "suitable_for_animals": False,
        "allergens": "Dairy, Gluten",
        "pickup_instructions": "Kitchen rear door"
    }
    status, new_listing, _ = request("/listings", method="POST", data=listing_payload, token=donor_token)
    print(f"POST /listings as donor -> Status {status}, Listing #{new_listing.get('listing_id')}, Pickup Code: {new_listing.get('pickup_code')}")
    assert status == 201
    created_listing_id = new_listing["listing_id"]
    secret_code = new_listing["pickup_code"]
    assert secret_code is not None, "Donor must receive the generated pickup code!"

    # Donor accessing /listings/my -> sees their listing AND pickup_code
    status, my_listings, _ = request("/listings/my", token=donor_token)
    print(f"GET /listings/my as donor -> Found {len(my_listings)} listing(s)")
    assert status == 200
    found = [l for l in my_listings if l["listing_id"] == created_listing_id]
    assert len(found) == 1 and found[0]["pickup_code"] == secret_code, "Donor must see pickup_code in /listings/my"
    print("Verified: Donor can see their own pickup_code in /listings/my")

    print("\n=== TEST 4: Receiver Login & Verification & Pickup Code Privacy ===")
    status, body, rec_cookie = request("/auth/login", method="POST", data={"email": "annapurna@trust.org", "password": "DemoPass123!"})
    print(f"POST /auth/login as receiver -> Status {status}, Role: {body['user']['role']}")
    assert status == 200
    rec_token = body["access_token"]

    # Receiver trying admin endpoint /users -> MUST be 403 Forbidden
    status, err, _ = request("/users", token=rec_token)
    print(f"Receiver accessing /users -> Status {status} (Expected 403)")
    assert status == 403

    # Receiver trying donor endpoint /listings (create) -> MUST be 403 Forbidden
    status, err, _ = request("/listings", method="POST", data=listing_payload, token=rec_token)
    print(f"Receiver trying to create listing -> Status {status} (Expected 403)")
    assert status == 403

    # Receiver accessing nearby listings -> MUST NOT see pickup_code
    status, nearby, _ = request("/receivers/my/listings", token=rec_token)
    print(f"Receiver accessing /receivers/my/listings -> Status {status}, Count: {len(nearby)}")
    assert status == 200
    for item in nearby:
        assert "pickup_code" not in item, "SECURITY FAIL: pickup_code exposed to receiver in nearby listings!"
    print("Verified: pickup_code is strictly HIDDEN from receivers in listings.")

    print("\n=== TEST 5: Match Lifecycle & Pickup Code Verification ===")
    # Admin runs matching
    status, match_run, _ = request("/matches/run", method="POST", token=admin_token)
    print(f"Admin running /matches/run -> Status {status}, Matches generated: {match_run.get('matched')}")
    assert status == 200

    # Receiver checks /matches
    status, rec_matches, _ = request("/matches", token=rec_token)
    print(f"Receiver accessing /matches -> Status {status}, Matches: {len(rec_matches)}")
    assert status == 200 and len(rec_matches) > 0
    for m in rec_matches:
        assert "pickup_code" not in m, "SECURITY FAIL: pickup_code exposed to receiver in matches list!"
    print("Verified: pickup_code is strictly HIDDEN from receiver in /matches.")

    test_match = rec_matches[0]
    match_id = test_match["match_id"]

    # Receiver accepts match
    status, update_res, _ = request(f"/matches/{match_id}", method="PATCH", data={"action": "accepted"}, token=rec_token)
    print(f"Receiver accepts match #{match_id} -> Status {status}")
    assert status == 200

    # Receiver attempts to pick up with WRONG pickup code -> MUST FAIL (400)
    status, err, _ = request(f"/matches/{match_id}", method="PATCH", data={"action": "picked_up", "pickup_code": "0000"}, token=rec_token)
    print(f"Receiver picking up with WRONG code ('0000') -> Status {status} (Expected 400)")
    assert status == 400, f"Expected 400, got {status}"
    print(f"Error message: {err.get('detail')}")

    # Query the actual donor pickup code for this match from DB
    import psycopg2, os
    from dotenv import load_dotenv
    load_dotenv()
    conn = psycopg2.connect(dbname="freshlink", user="postgres", password=os.getenv("DB_PASSWORD"), host="localhost", port="5432")
    with conn.cursor() as cur:
        cur.execute("SELECT f.pickup_code FROM matches m JOIN food_listings f ON f.listing_id = m.listing_id WHERE m.match_id = %s", (match_id,))
        actual_code = cur.fetchone()[0]
    conn.close()

    # Receiver picks up with CORRECT code
    status, pickup_res, _ = request(f"/matches/{match_id}", method="PATCH", data={"action": "picked_up", "pickup_code": str(actual_code)}, token=rec_token)
    print(f"Receiver picking up with CORRECT code ('{actual_code}') -> Status {status} (Success)")
    assert status == 200, f"Expected 200, got {status}"

    # Receiver marks delivered
    status, deliv_res, _ = request(f"/matches/{match_id}", method="PATCH", data={"action": "completed"}, token=rec_token)
    print(f"Receiver completing delivery -> Status {status} (Success)")
    assert status == 200

    print("\n=== TEST 6: Logout Endpoint ===")
    status, logout_res, _ = request("/auth/logout", method="POST")
    print(f"POST /auth/logout -> Status {status}")
    assert status == 200

    print("\n=======================================================")
    print("ALL SECURITY AND PERMISSION TESTS PASSED PERFECTLY!")
    print("=======================================================")

if __name__ == "__main__":
    run_tests()
