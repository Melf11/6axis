#!/usr/bin/env python3
"""Who may use the bug-report chat and whose reports are processed automatically.

The decision is made here, in plain code – never by the AI agent. Workflows call it with the issue and
its timeline events (from the GitHub API) and the configuration from the main branch.

  python3 scripts/bug_automation.py decide --config .github/bug-automation.yml --issue issue.json --events events.json
  → {"reporter": true, "autofix": true, "reason": "..."}
"""
import argparse
import json
import sys


def load_config(text):
    """Tiny parser for the subset used in .github/bug-automation.yml (lists of names, integers, comments)."""
    config, key = {}, None
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].rstrip()
        if not line.strip():
            continue
        if line.startswith((" ", "\t")) and line.strip().startswith("- ") and key:
            config.setdefault(key, []).append(line.strip()[2:].strip().strip("'\""))
        elif ":" in line and not line.startswith((" ", "\t")):
            key, value = (part.strip() for part in line.split(":", 1))
            if value:
                config[key] = int(value) if value.isdigit() else value.strip("'\"")
                key = None
            else:
                config[key] = []
    return config


def names(config, key):
    return {str(n).lower() for n in config.get(key, []) if isinstance(config.get(key), list)}


def decide(issue, events, config, owner):
    """Decision for one issue. `owner` is the repository owner (the only one who may approve)."""
    author = (issue.get("user") or {}).get("login", "")
    labels = {l.get("name") if isinstance(l, dict) else l for l in issue.get("labels", [])}
    reporter = author.lower() in names(config, "reporters")
    if "pull_request" in issue:
        return {"reporter": False, "autofix": False, "reason": "pull request, not an issue"}
    if author.lower() in names(config, "autofix"):
        return {"reporter": reporter, "autofix": True, "reason": f"@{author} is in autofix"}
    # Approval: the label 'freigegeben' must have been added by the owner (checked in the timeline).
    approved_by = [e.get("actor", {}).get("login", "") for e in events
                   if e.get("event") == "labeled" and (e.get("label") or {}).get("name") == "freigegeben"]
    if "freigegeben" in labels and any(a.lower() == owner.lower() for a in approved_by):
        return {"reporter": reporter, "autofix": True, "reason": f"approved by @{owner}"}
    if "freigegeben" in labels:
        return {"reporter": reporter, "autofix": False, "reason": "label 'freigegeben' not set by the owner"}
    return {"reporter": reporter, "autofix": False, "reason": f"@{author} is not in autofix and not approved"}


def main(argv=None):
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    d = sub.add_parser("decide")
    d.add_argument("--config", required=True)
    d.add_argument("--issue", required=True)
    d.add_argument("--events", required=True)
    d.add_argument("--owner", default="Melf11")
    a = p.parse_args(argv)
    with open(a.config, encoding="utf-8") as f:
        config = load_config(f.read())
    with open(a.issue, encoding="utf-8") as f:
        issue = json.load(f)
    with open(a.events, encoding="utf-8") as f:
        events = json.load(f)
    json.dump(decide(issue, events, config, a.owner), sys.stdout)
    print()


if __name__ == "__main__":
    main()
