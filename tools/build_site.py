#!/usr/bin/env python3
"""
Builds the public website from the tidy `site/` folder.

  site/main/          -> /               (index.html, app.html, admin.html, sw.js, manifest, .well-known)
  site/seo-and-ai/    -> /               (robots.txt, sitemap.xml, llms.txt, IndexNow key)
  site/images/        -> /               (icons, og.png)
  site/legal/         -> /               (terms.html, privacy.html, ...)
  site/pages/<page>/  -> /<page>/        (about, faq, guides, ...)
  site/city-pages/<group>/<page>/ -> /<page>/   (e.g. city-pages/birthday-photographers/birthday-photographers-in-pune/
                                                 is published as /birthday-photographers-in-pune/)

So every web address stays exactly the same; the folders are only grouped for people.
Usage: python3 tools/build_site.py [output folder, default: dist]
"""
import os, shutil, sys

WEB = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SITE = os.path.join(WEB, "site")
OUT = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.path.join(WEB, "dist")
ROOT_GROUPS = ["main", "seo-and-ai", "images", "legal"]

placed = {}
def put(src, name):
    if name in placed:
        sys.exit(f"ERROR: two things want /{name}: {placed[name]} and {os.path.relpath(src, WEB)}")
    placed[name] = os.path.relpath(src, WEB)
    dst = os.path.join(OUT, name)
    if os.path.isdir(src): shutil.copytree(src, dst)
    else: shutil.copy2(src, dst)

if os.path.exists(OUT): shutil.rmtree(OUT)
os.makedirs(OUT)
for top in sorted(os.listdir(SITE)):
    if top.startswith(".") or top.lower() in ("readme.txt", "readme.md"): continue
    if top not in ROOT_GROUPS + ["pages", "city-pages"]:
        sys.exit(f"ERROR: unknown folder site/{top} - add it to tools/build_site.py")
for g in ROOT_GROUPS:
    for name in sorted(os.listdir(os.path.join(SITE, g))):
        put(os.path.join(SITE, g, name), name)
for name in sorted(os.listdir(os.path.join(SITE, "pages"))):
    put(os.path.join(SITE, "pages", name), name)
for group in sorted(os.listdir(os.path.join(SITE, "city-pages"))):
    gd = os.path.join(SITE, "city-pages", group)
    if not os.path.isdir(gd): continue
    for name in sorted(os.listdir(gd)):
        put(os.path.join(gd, name), name)
for must in ("index.html", "app.html", "sw.js", "sitemap.xml", "robots.txt"):
    if not os.path.exists(os.path.join(OUT, must)): sys.exit(f"ERROR: {must} missing from the build")
print(f"Built {len(placed)} top-level items into {os.path.relpath(OUT, WEB)}/")
