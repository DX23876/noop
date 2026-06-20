#!/usr/bin/env python3
"""Refresh the homepage stat badges (docs/stats/*.json) from the live GitHub API.

The README shows shields.io `endpoint` badges that read these public raw JSON files, so the
stars/forks/issue counts etc. stay current. Run on a schedule or at release time.

Reads counts from the GitHub API (https://api.github.com/repos/NoopApp/noop) using the token
at ~/.config/noop/gh_token. Writes the docs/stats/*.json files to the LOCAL working tree only;
committing + pushing is left to the normal multi-push git flow (which also mirrors to noop.fans),
so the working tree stays the single source of truth and no API-side divergence is created.
"""
import urllib.request, urllib.error, urllib.parse, json, os
TOK=open(os.path.expanduser("~/.config/noop/gh_token")).read().strip()
API="https://api.github.com/repos/NoopApp/noop"
HERE=os.path.dirname(os.path.abspath(__file__))
ROOT=os.path.dirname(HERE)
def req(url):
    h={"Authorization":"token "+TOK,"Accept":"application/vnd.github+json",
       "X-GitHub-Api-Version":"2022-11-28","User-Agent":"noop-stats-badges"}
    r=urllib.request.urlopen(urllib.request.Request(url,headers=h),timeout=30)
    return r.status, r.read()
def write(path, label, message, color):
    content=json.dumps({"schemaVersion":1,"label":label,"message":str(message),"color":color})
    full=os.path.join(ROOT,path)
    os.makedirs(os.path.dirname(full),exist_ok=True)
    with open(full,"w") as f: f.write(content)
def search_count(q):
    # GitHub Search API returns total_count without paginating every result.
    url="https://api.github.com/search/issues?per_page=1&q="+urllib.parse.quote(q)
    _,b=req(url); return json.loads(b).get("total_count",0)
_,b=req(API); repo=json.loads(b)
_,b=req(API+"/releases/latest"); latest=json.loads(b)
_,b=req(API+"/commits?per_page=1"); last=json.loads(b)[0]["commit"]["author"]["date"][:10]
# open_issues_count on the repo includes PRs; use the search API to count issues only.
open_issues=search_count("repo:NoopApp/noop is:issue is:open")
resolved=search_count("repo:NoopApp/noop is:issue is:closed")
write("docs/stats/release.json","latest",latest["tag_name"],"E8B84B")
write("docs/stats/released.json","released",(latest.get("published_at") or "")[:10],"6B737B")
write("docs/stats/stars.json","stars",repo.get("stargazers_count",0),"E8B84B")
write("docs/stats/forks.json","forks",repo.get("forks_count",0),"6B737B")
write("docs/stats/open.json","open issues",open_issues,"E8B84B")
write("docs/stats/resolved.json","resolved",resolved,"C8902F")
write("docs/stats/lastcommit.json","last commit",last,"6B737B")
print(f"refreshed: latest {latest['tag_name']}, {repo.get('stargazers_count',0)} stars, "
      f"{open_issues} open, {resolved} resolved")
