"""Check the real Dune @doc output, not a separately rendered copy of the guide.

Run after `dune build @doc`: python3 -B test/journal_documentation_test.py
The build graph owns this regression; no application reducer can reproduce it.
"""

from html.parser import HTMLParser
from pathlib import Path
import re
import unittest
from urllib.parse import unquote, urlsplit


ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / "_build/default"
HTML = BUILD / "_doc/_html"
PACKAGE_INDEX = HTML / "logseq_journal/index.html"
GUIDE = HTML / "logseq_journal/journal_execution_flow.html"


def normalized(text):
    return " ".join(text.split())


class Page(HTMLParser):
    def __init__(self, path):
        super().__init__()
        self.links = []
        self.ids = set()
        self.code_blocks = []
        self.text = []
        self.pre = None
        self.feed(path.read_text())

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if "id" in attrs:
            self.ids.add(attrs["id"])
        if tag == "a" and "href" in attrs:
            self.links.append(attrs["href"])
        if tag == "pre":
            self.pre = []

    def handle_endtag(self, tag):
        if tag == "pre" and self.pre is not None:
            self.code_blocks.append("".join(self.pre))
            self.pre = None

    def handle_data(self, data):
        self.text.append(data)
        if self.pre is not None:
            self.pre.append(data)


class JournalDocumentationTests(unittest.TestCase):
    def test_generated_manual_uses_the_complete_mli_body(self):
        source = (ROOT / "app/spec/journal_execution_flow.mli").read_text().strip()
        self.assertTrue(source.startswith("(**") and source.endswith("*)"))
        self.assertEqual(source.count("(*"), 1)
        self.assertEqual(source.count("*)"), 1)
        generated = BUILD / "app/spec/journal_execution_flow.mld"
        self.assertTrue(generated.is_file(), "@doc did not generate the guide manual")
        self.assertEqual(
            generated.read_text().strip(),
            "{0 Journal execution flow}\n\n" + source[3:-2].strip(),
        )
        self.assertFalse((ROOT / "app/spec/journal_execution_flow.mld").exists(),
                         "The generated manual must not become a second source")

    def test_package_index_links_to_guide_and_existing_api(self):
        self.assertTrue(PACKAGE_INDEX.is_file(), "@doc package index is missing")
        links = Page(PACKAGE_INDEX).links
        self.assertIn("journal_execution_flow.html", links)
        self.assertIn("Journal_worker_coordination/index.html", links)
        self.assertTrue(GUIDE.is_file(), "The guide link must resolve to generated HTML")
        self.assertIn("logseq_journal/index.html", Page(HTML / "index.html").links)

    def test_rendered_guide_keeps_all_sections_and_examples(self):
        self.assertTrue(GUIDE.is_file(), "@doc did not render the guide")
        source = (ROOT / "app/spec/journal_execution_flow.mli").read_text()
        page = Page(GUIDE)
        rendered = normalized(" ".join(page.text))
        headings = re.findall(r"\{[12] ([^}]+)\}", source)
        for heading in headings:
            with self.subTest(heading=heading):
                self.assertIn(normalized(heading), rendered)
        blocks = re.findall(r"\{\[(.*?)\]\}|\{v(.*?)v\}", source, re.S)
        expected = [normalized(code or trace) for code, trace in blocks]
        self.assertEqual([normalized(code) for code in page.code_blocks], expected)
        self.assertIn("It explains the major paths, not every UI branch, protocol error, "
                      "asset codec or storage implementation detail.", rendered)

    def test_index_and_guide_local_links_resolve(self):
        for path in (PACKAGE_INDEX, GUIDE):
            self.assertTrue(path.is_file(), f"Missing generated page: {path.name}")
            for href in Page(path).links:
                link = urlsplit(href)
                if link.scheme or link.netloc:
                    continue
                target = (path.parent / unquote(link.path)).resolve() if link.path else path
                with self.subTest(page=path.name, href=href):
                    self.assertTrue(target.is_file(), f"Broken local link: {href}")
                    if link.fragment:
                        self.assertIn(unquote(link.fragment), Page(target).ids)


if __name__ == "__main__":
    unittest.main()
