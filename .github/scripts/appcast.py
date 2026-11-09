#!/usr/bin/env python3
"""
Writes the Sparkle update feed (appcast.xml) for one release.

    appcast.py VERSION MIN_MACOS ZIP_URL ZIP_PATH SIGNATURE NOTES_MD > appcast.xml

The app checks this feed (published as a release asset, so "releases/latest/download/appcast.xml"
always points at the newest one). SIGNATURE is the EdDSA signature of the zip from
`sign_update -p`; the feed itself is signed afterwards with `sign_update appcast.xml`.
NOTES_MD is a Markdown file shown to the user in the update window.
"""
import os
import sys
from email.utils import formatdate
from xml.sax.saxutils import escape, quoteattr


def main():
    version, min_os, url, zip_path, signature, notes_path = sys.argv[1:7]
    if min_os.count(".") == 1:          # Sparkle wants three parts, e.g. 14.0.0
        min_os += ".0"
    with open(notes_path, encoding="utf-8") as f:
        notes = f.read().strip().replace("]]>", "]]]]><![CDATA[>")
    length = os.path.getsize(zip_path)
    print(f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>D-Log Tagger</title>
    <link>https://github.com/granthorner-1980/dlog-tagger</link>
    <item>
      <title>Version {escape(version)}</title>
      <pubDate>{formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{escape(version)}</sparkle:version>
      <sparkle:shortVersionString>{escape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{escape(min_os)}</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/granthorner-1980/dlog-tagger/blob/main/CHANGELOG.md</sparkle:fullReleaseNotesLink>
      <description sparkle:format="markdown"><![CDATA[
{notes}
]]></description>
      <enclosure url={quoteattr(url)} length="{length}" type="application/octet-stream"
                 sparkle:edSignature={quoteattr(signature)}/>
    </item>
  </channel>
</rss>""")


if __name__ == "__main__":
    main()
