#!/usr/bin/env python3
"""
CLI utility to create an administrator account for FreshLink.
Usage:
    python backend/create_admin.py --email admin@example.com --password "MySecretPass123!" --name "Alice Admin" --phone "9876543210"
Or run interactively:
    python backend/create_admin.py
"""

import argparse
import getpass
import os
import sys
from pathlib import Path
import psycopg2
import psycopg2.extras
import bcrypt
from dotenv import load_dotenv

# Load .env
env_path = Path(__file__).resolve().parent.parent / ".env"
load_dotenv(dotenv_path=env_path)
load_dotenv()

DB_CONFIG = {
    "dbname":   os.getenv("DB_NAME",     "freshlink"),
    "user":     os.getenv("DB_USER",     "postgres"),
    "password": os.getenv("DB_PASSWORD", ""),
    "host":     os.getenv("DB_HOST",     "localhost"),
    "port":     os.getenv("DB_PORT",     "5432"),
}

def hash_password(password: str) -> str:
    salt = bcrypt.gensalt(rounds=12)
    return bcrypt.hashpw(password.encode("utf-8"), salt).decode("utf-8")

def main():
    parser = argparse.ArgumentParser(description="Create a FreshLink Admin Account")
    parser.add_argument("--email", help="Admin email address")
    parser.add_argument("--password", help="Admin password")
    parser.add_argument("--name", help="Admin full name")
    parser.add_argument("--phone", help="Admin contact phone")
    args = parser.parse_args()

    email = args.email or input("Admin Email: ").strip()
    if not email:
        print("Error: Email is required.")
        sys.exit(1)

    password = args.password
    if not password:
        password = getpass.getpass("Admin Password: ").strip()
        confirm = getpass.getpass("Confirm Password: ").strip()
        if password != confirm:
            print("Error: Passwords do not match.")
            sys.exit(1)

    if len(password) < 6:
        print("Error: Password must be at least 6 characters.")
        sys.exit(1)

    name = args.name or input("Full Name [Admin]: ").strip() or "Admin"
    phone = args.phone or input("Phone [9999999999]: ").strip() or "9999999999"

    password_hash = hash_password(password)

    try:
        conn = psycopg2.connect(**DB_CONFIG)
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            # Check if email exists
            cur.execute("SELECT user_id, role FROM users WHERE email = %s", (email,))
            existing = cur.fetchone()
            if existing:
                cur.execute(
                    """
                    UPDATE users
                    SET password_hash = %s, full_name = %s, phone = %s, role = 'admin', is_active = TRUE
                    WHERE email = %s
                    RETURNING user_id, email, full_name, role
                    """,
                    (password_hash, name, phone, email)
                )
                conn.commit()
                row = cur.fetchone()
                print(f"[SUCCESS] Existing user upgraded/updated as admin: User ID #{row['user_id']} ({row['email']})")
            else:
                cur.execute(
                    """
                    INSERT INTO users (email, password_hash, full_name, phone, role, is_active)
                    VALUES (%s, %s, %s, %s, 'admin', TRUE)
                    RETURNING user_id, email, full_name, role
                    """,
                    (email, password_hash, name, phone)
                )
                conn.commit()
                row = cur.fetchone()
                print(f"[SUCCESS] Created new Admin account: User ID #{row['user_id']} ({row['email']})")
        conn.close()
    except Exception as e:
        print(f"[ERROR] Database error: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
