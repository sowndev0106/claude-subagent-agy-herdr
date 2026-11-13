"""Read account identity without exposing or rewriting agy's credentials."""
import base64
import json
import sys


def account_email(document):
    if not isinstance(document, dict):
        return ""
    # Current agy stores an OAuth2 token and its cached identity separately.
    if "token" in document:
        token = document["token"]
        if not isinstance(token, dict) or not (token.get("access_token") or token.get("refresh_token")):
            return ""
        email = document.get("id_token_email")
        if isinstance(email, str) and email.strip() and not any(c.isspace() for c in email):
            return email if "@" in email else ""
    # Older agy stored the identity JWT at the top level. This only reads
    # identity; expiry/refresh and credential validation remain agy's job.
    try:
        claim = document["id_token"].split(".")[1]
        email = json.loads(base64.urlsafe_b64decode(claim + "=" * (-len(claim) % 4))).get("email")
        return email if isinstance(email, str) and "@" in email and not any(c.isspace() for c in email) else ""
    except (ValueError, KeyError, IndexError, TypeError, AttributeError):
        return ""


def file_email(path):
    try:
        with open(path, encoding="utf-8") as stream:
            return account_email(json.load(stream))
    except (OSError, ValueError, UnicodeError):
        return ""


def main():
    try:
        if sys.argv[1:] == ["--keyring", "Darwin"]:
            import subprocess
            raw = subprocess.check_output(["security", "find-generic-password", "-s", "gemini",
                                           "-a", "antigravity", "-w"], stderr=subprocess.DEVNULL, timeout=10)
            email = account_email(json.loads(raw))
        elif sys.argv[1:] == ["--keyring", "Linux"]:
            import secretstorage
            collection = secretstorage.get_default_collection(secretstorage.dbus_init())
            item = next(collection.search_items({"service": "gemini", "username": "antigravity"}))
            email = account_email(json.loads(item.get_secret().decode()))
        elif sys.argv[1:] == ["-"]:
            email = account_email(json.load(sys.stdin))
        else:
            email = file_email(sys.argv[1])
    except Exception:
        # Keyring backends can throw OS-specific exceptions; never print their
        # payloads, which may include credential material.
        return 1
    if not email:
        return 1
    print(email)
    return 0


if __name__ == "__main__":
    sys.exit(main())
