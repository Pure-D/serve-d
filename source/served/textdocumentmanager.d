module served.textdocumentmanager;

import std.algorithm;
import std.json;
import std.utf : decode;

import served.jsonrpc;
import served.protocol;

import painlessjson;

struct Document
{
	DocumentUri uri;
	string languageId;
	long version_;
	string text;

	this(DocumentUri uri)
	{
		this.uri = uri;
		languageId = "d";
		version_ = 0;
		text = "";
	}

	this(TextDocumentItem doc)
	{
		uri = doc.uri;
		languageId = doc.languageId;
		version_ = doc.version_;
		text = doc.text;
	}

	size_t positionToOffset(Position position)
	{
		size_t index = 0;
		size_t offset = 0;
		Position cur;
		while (index < text.length)
		{
			if (position == cur)
				return offset;
			auto c = decode(text, index);
			offset++;
			cur.character++;
			if (c == '\n')
			{
				if (cur.line == position.line)
					return offset - 1; // end of line
				cur.character = 0;
				cur.line++;
			}
		}
		return offset;
	}

	size_t positionToBytes(Position position)
	{
		size_t index = 0;
		Position cur;
		while (index < text.length)
		{
			if (position == cur)
				return index;
			auto c = decode(text, index);
			cur.character++;
			if (c == '\n')
			{
				if (cur.line == position.line)
					return index - 1; // end of line
				cur.character = 0;
				cur.line++;
			}
		}
		return text.length;
	}

	Position offsetToPosition(size_t offset)
	{
		size_t index = 0;
		size_t offs = 0;
		Position cur;
		while (index < text.length)
		{
			if (offs >= offset)
				return cur;
			auto c = decode(text, index);
			offs++;
			cur.character++;
			if (c == '\n')
			{
				cur.character = 0;
				cur.line++;
			}
		}
		return cur;
	}

	Position bytesToPosition(size_t offset)
	{
		size_t index = 0;
		Position cur;
		while (index < text.length)
		{
			if (index >= offset)
				return cur;
			auto c = decode(text, index);
			cur.character++;
			if (c == '\n')
			{
				cur.character = 0;
				cur.line++;
			}
		}
		return cur;
	}

	string lineAt(Position position)
	{
		size_t index = 0;
		size_t lineStart = 0;
		bool wasStart = true;
		bool found = false;
		Position cur;
		while (index < text.length)
		{
			if (wasStart)
			{
				if (cur.line == position.line)
				{
					lineStart = index;
					found = true;
				}
				if (cur.line == position.line + 1)
					break;
			}
			wasStart = false;
			auto c = decode(text, index);
			cur.character++;
			if (c == '\n')
			{
				wasStart = true;
				cur.character = 0;
				cur.line++;
			}
		}
		if (!found)
			return "";
		return text[lineStart .. index];
	}

	unittest
	{
		import fluent.asserts;

		Document doc;
		doc.text = `abc
hellö world
how åre
you?`;
		Assert.equal(doc.lineAt(Position(0, 0)), "abc\n");
		Assert.equal(doc.lineAt(Position(0, 100)), "abc\n");
		Assert.equal(doc.lineAt(Position(1, 3)), "hellö world\n");
		Assert.equal(doc.lineAt(Position(2, 0)), "how åre\n");
		Assert.equal(doc.lineAt(Position(3, 0)), "you?");
		Assert.equal(doc.lineAt(Position(3, 8)), "you?");
		Assert.equal(doc.lineAt(Position(4, 0)), "");
	}

	EolType eolAt(int line)
	{
		size_t index = 0;
		int curLine = 0;
		bool prevWasCr = false;
		while (index < text.length)
		{
			if (curLine > line)
				return EolType.lf;
			auto c = decode(text, index);
			if (c == '\n')
			{
				if (curLine == line)
				{
					return prevWasCr ? EolType.crlf : EolType.lf;
				}
				curLine++;
			}
			prevWasCr = c == '\r';
		}
		return EolType.lf;
	}
}

struct TextDocumentManager
{
	Document[] documentStore;

	ref Document opIndex(string uri)
	{
		auto idx = documentStore.countUntil!(a => a.uri == uri);
		if (idx == -1)
			throw new Exception("Document '" ~ uri ~ "' not found");
		return documentStore[idx];
	}

	Document tryGet(string uri)
	{
		auto idx = documentStore.countUntil!(a => a.uri == uri);
		if (idx == -1)
			return Document.init;
		return documentStore[idx];
	}

	static TextDocumentSyncKind syncKind()
	{
		return TextDocumentSyncKind.incremental;
	}

	bool process(RequestMessage msg)
	{
		import std.stdio;

		if (msg.method == "textDocument/didOpen")
		{
			auto params = msg.params.fromJSON!DidOpenTextDocumentParams;
			documentStore ~= Document(params.textDocument);
			return true;
		}
		else if (msg.method == "textDocument/didClose")
		{
			auto idx = documentStore.countUntil!(a => a.uri == msg.params["textDocument"]["uri"].str);
			if (idx >= 0)
			{
				documentStore[idx] = documentStore[$ - 1];
				documentStore.length--;
			}
			return true;
		}
		else if (msg.method == "textDocument/didChange")
		{
			auto idx = documentStore.countUntil!(a => a.uri == msg.params["textDocument"]["uri"].str);
			if (idx >= 0)
			{
				documentStore[idx].version_ = msg.params["textDocument"]["version"].integer;
				foreach (change; msg.params["contentChanges"].array)
				{
					auto rangePtr = "range" in change;
					if (!rangePtr)
					{
						documentStore[idx].text = change["text"].str;
						break;
					}
					auto range = *rangePtr;
					TextRange textRange = [range["start"].fromJSON!Position, range["end"].fromJSON!Position];
					auto start = documentStore[idx].positionToBytes(textRange[0]);
					auto end = documentStore[idx].positionToBytes(textRange[1]);
					if (start > end)
					{
						auto tmp = start;
						start = end;
						end = tmp;
					}
					documentStore[idx].text = documentStore[idx].text[0 .. start]
						~ change["text"].str ~ documentStore[idx].text[end .. $];
				}
			}
			return true;
		}
		return false;
	}
}
