module served.lsp.textdocumentmanager;

import std.algorithm;
import std.experimental.logger;
import std.json;
import std.string;
import std.utf : codeLength, decode, UseReplacementDchar;

import served.lsp.jsonrpc;
import served.lsp.protocol;

import painlessjson;

struct Document
{
	DocumentUri uri;
	string languageId;
	long version_;
	private char[] text;

	this(DocumentUri uri)
	{
		this.uri = uri;
		languageId = "d";
		version_ = 0;
		text = null;
	}

	this(TextDocumentItem doc)
	{
		uri = doc.uri;
		languageId = doc.languageId;
		version_ = doc.version_;
		text = doc.text.dup;
	}

	static Document nullDocument(scope const(char)[] content)
	{
		Document ret;
		ret.setContent(content);
		return ret;
	}

	version (unittest) private static Document nullDocumentOwnMemory(char[] content)
	{
		Document ret;
		ret.text = content;
		return ret;
	}

	const(char)[] rawText()
	{
		return cast(const(char)[]) text;
	}

	size_t length() const @property
	{
		return text.length;
	}

	void setContent(scope const(char)[] newContent)
	{
		if (newContent.length <= text.length)
		{
			text[0 .. newContent.length] = newContent;
			text.length = newContent.length;
		}
		else
		{
			text = text.assumeSafeAppend;
			text.length = newContent.length;
			text = text.assumeSafeAppend;
			text[0 .. $] = newContent;
		}
	}

	void applyChange(TextRange range, scope const(char)[] newContent)
	{
		auto start = positionToBytes(range[0]);
		auto end = positionToBytes(range[1]);

		if (start > end)
			swap(start, end);

		if (start == 0 && end == text.length)
		{
			setContent(newContent);
			return;
		}

		auto addition = newContent.representation;
		int removed = cast(int) end - cast(int) start;
		int added = cast(int) addition.length - removed;
		text = text.assumeSafeAppend;
		if (added > 0)
		{
			text.length += added;
			// text[end + added .. $] = text[end .. $ - added];
			for (int i = cast(int) text.length - 1; i >= end + added; i--)
				text[i] = text[i - added];
		}
		else if (added < 0)
		{
			for (size_t i = start; i < text.length + added; i++)
				text[i] = text[i - added];

			text = text[0 .. $ + added];
		}
		text = text.assumeSafeAppend;

		foreach (i, c; addition)
			text[start + i] = cast(char) c;
	}

	size_t offsetToBytes(size_t offset)
	{
		size_t bytes;
		size_t index;
		while (index < offset && bytes < text.length)
		{
			const c = decode!(UseReplacementDchar.yes)(text, bytes);
			index += c.codeLength!wchar;
		}
		return bytes;
	}

	size_t bytesToOffset(size_t bytes)
	{
		size_t offset;
		size_t index;
		while (index < bytes)
		{
			const c = decode!(UseReplacementDchar.yes)(text, index);
			offset += c.codeLength!wchar;
		}
		return offset;
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
			const c = decode!(UseReplacementDchar.yes)(text, index);
			offset += c.codeLength!wchar;
			cur.character += c.codeLength!wchar;
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
			const c = decode!(UseReplacementDchar.yes)(text, index);
			cur.character += c.codeLength!wchar;
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
			const c = decode!(UseReplacementDchar.yes)(text, index);
			offs += c.codeLength!wchar;
			cur.character += c.codeLength!wchar;
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
			const c = decode!(UseReplacementDchar.yes)(text, index);
			cur.character += c.codeLength!wchar;
			if (c == '\n')
			{
				cur.character = 0;
				cur.line++;
			}
		}
		return cur;
	}

	TextRange wordRangeAt(Position position)
	{
		auto chars = wordInLine(lineAt(position), position.character);
		return TextRange(Position(position.line, chars[0]), Position(position.line, chars[1]));
	}

	size_t[2] lineByteRangeAt(uint line)
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
				if (cur.line == line)
				{
					lineStart = index;
					found = true;
				}
				if (cur.line == line + 1)
					break;
			}
			wasStart = false;
			const c = decode!(UseReplacementDchar.yes)(text, index);
			cur.character += c.codeLength!wchar;
			if (c == '\n')
			{
				wasStart = true;
				cur.character = 0;
				cur.line++;
			}
		}
		if (!found)
			return [0, 0];
		return [lineStart, index];
	}

	/// Returns the text of a line at the given position.
	string lineAt(Position position)
	{
		return lineAt(position.line);
	}

	/// Returns the text of a line starting at line 0.
	string lineAt(uint line)
	{
		auto range = lineByteRangeAt(line);
		return text[range[0] .. range[1]].idup;
	}

	unittest
	{
		void assertEqual(A, B)(A a, B b)
		{
			import std.conv : to;

			assert(a == b, a.to!string ~ " is not equal to " ~ b.to!string);
		}

		Document doc;
		doc.setContent(`abc
hellö world
how åre
you?`);
		assertEqual(doc.lineAt(Position(0, 0)), "abc\n");
		assertEqual(doc.lineAt(Position(0, 100)), "abc\n");
		assertEqual(doc.lineAt(Position(1, 3)), "hellö world\n");
		assertEqual(doc.lineAt(Position(2, 0)), "how åre\n");
		assertEqual(doc.lineAt(Position(3, 0)), "you?");
		assertEqual(doc.lineAt(Position(3, 8)), "you?");
		assertEqual(doc.lineAt(Position(4, 0)), "");
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
			auto c = decode!(UseReplacementDchar.yes)(text, index);
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
		if (msg.method == "textDocument/didOpen")
		{
			auto params = msg.params.fromJSON!DidOpenTextDocumentParams;
			documentStore ~= Document(params.textDocument);
			return true;
		}
		else if (msg.method == "textDocument/didClose")
		{
			auto targetUri = msg.params["textDocument"]["uri"].str;
			auto idx = documentStore.countUntil!(a => a.uri == targetUri);
			if (idx >= 0)
			{
				documentStore[idx] = documentStore[$ - 1];
				documentStore.length--;
			}
			else
			{
				warning("Received didClose notification for URI not in system: ", targetUri);
				warning(
						"This can be a potential memory leak if it was previously opened under a different name.");
			}
			return true;
		}
		else if (msg.method == "textDocument/didChange")
		{
			auto targetUri = msg.params["textDocument"]["uri"].str;
			auto idx = documentStore.countUntil!(a => a.uri == targetUri);
			if (idx >= 0)
			{
				documentStore[idx].version_ = msg.params["textDocument"]["version"].integer;
				foreach (change; msg.params["contentChanges"].array)
				{
					if (auto rangePtr = "range" in change)
					{
						auto range = *rangePtr;
						TextRange textRange = cast(Position[2])[
							range["start"].fromJSON!Position, range["end"].fromJSON!Position
						];
						documentStore[idx].applyChange(textRange, change["text"].str);
					}
					else
						documentStore[idx].setContent(change["text"].str);
				}
			}
			return true;
		}
		return false;
	}
}

struct PerDocumentCache(T)
{
	struct Entry
	{
		Document document;
		T data;
	}

	Entry[] entries;

	T cached(ref TextDocumentManager source, string uri)
	{
		auto newest = source.tryGet(uri);
		foreach (entry; entries)
			if (entry.document.uri == uri)
			{
				if (entry.document.version_ >= newest.version_)
					return entry.data;
				else
					return T.init;
			}
		return T.init;
	}

	void store(Document document, T data)
	{
		foreach (ref entry; entries)
		{
			if (entry.document.uri == document.uri)
			{
				if (document.version_ >= entry.document.version_)
				{
					entry.document = document;
					entry.data = data;
				}
				return;
			}
		}
		entries ~= Entry(document, data);
	}
}

/// Returns a range of the identifier/word at the given position.
uint[2] wordInLine(string line, uint character)
{
	size_t index = 0;
	uint offs = 0;

	uint lastStart = character;
	uint start = character, end = character + 1;
	bool searchStart = true;

	while (index < line.length)
	{
		const c = decode(line, index);
		const l = cast(uint) c.codeLength!wchar;

		if (searchStart)
		{
			if (isIdentifierSeparatingChar(c))
				lastStart = offs + l;

			if (offs + l >= character)
			{
				start = lastStart;
				searchStart = false;
			}

			offs += l;
		}
		else
		{
			end = offs;
			offs += l;
			if (isIdentifierSeparatingChar(c))
				break;
		}
	}
	return [start, end];
}

bool isIdentifierSeparatingChar(dchar c)
{
	return c < 48 || (c > 57 && c < 65) || c == '[' || c == '\\' || c == ']'
		|| c == '`' || (c > 122 && c < 128) || c == '\u2028' || c == '\u2029'; // line separators
}

unittest
{
	Document doc;
	doc.text.reserve(16);
	auto ptr = doc.text.ptr;
	assert(doc.rawText.length == 0);
	doc.setContent("Hello world");
	assert(doc.rawText == "Hello world");
	doc.setContent("foo");
	assert(doc.rawText == "foo");
	doc.setContent("foo bar baz baf");
	assert(doc.rawText == "foo bar baz baf");
	doc.applyChange(TextRange(0, 4, 0, 8), "");
	assert(doc.rawText == "foo baz baf");
	doc.applyChange(TextRange(0, 4, 0, 8), "bad");
	assert(doc.rawText == "foo badbaf");
	doc.applyChange(TextRange(0, 4, 0, 8), "bath");
	assert(doc.rawText == "foo bathaf");
	doc.applyChange(TextRange(0, 4, 0, 10), "bath");
	assert(doc.rawText == "foo bath");
	doc.applyChange(TextRange(0, 0, 0, 8), "bath");
	assert(doc.rawText == "bath");
	doc.applyChange(TextRange(0, 0, 0, 1), "par");
	assert(doc.rawText == "parath", doc.rawText);
	doc.applyChange(TextRange(0, 0, 0, 4), "");
	assert(doc.rawText == "th");
	doc.applyChange(TextRange(0, 2, 0, 2), "e");
	assert(doc.rawText == "the");
	doc.applyChange(TextRange(0, 0, 0, 0), "in");
	assert(doc.rawText == "inthe");
	assert(ptr is doc.text.ptr);
}

size_t countUTF16Length(const(char)[] s)
{
	size_t offset;
	size_t index;
	while (index < s.length)
	{
		const c = decode!(UseReplacementDchar.yes)(s, index);
		offset += c.codeLength!wchar;
	}
	return offset;
}

version (unittest)
{
	Document testUnicodeDocument = Document.nullDocumentOwnMemory(cast(char[]) `///
/// Copyright © 2020 Somebody (not actually™) x3
///
module some.file;

enum Food : int
{
	pizza = '\U0001F355', // 🍕
	burger = '\U0001F354', // 🍔
	chicken = '\U0001F357', // 🍗
	taco = '\U0001F32E', // 🌮
	wrap = '\U0001F32F', // 🌯
	salad = '\U0001F957', // 🥗
	pasta = '\U0001F35D', // 🍝
	sushi = '\U0001F363', // 🍣
	oden = '\U0001F362', // 🍢
	egg = '\U0001F373', // 🍳
	croissant = '\U0001F950', // 🥐
	baguette = '\U0001F956', // 🥖
	popcorn = '\U0001F37F', // 🍿
	coffee = '\u2615', // ☕
	cookie = '\U0001F36A', // 🍪
}

void main() {
	// taken from https://github.com/DlangRen/Programming-in-D/blob/master/ddili/src/ders/d.cn/aa.d
	int[string] colorCodes = [ /* ... */ ];

	if ("purple" in colorCodes) {
		// ü®™🍳键 “purple” 在表中

	} else { // line 31
		//表中不存在 键 “purple” 
	}

	string x;
}`);

	enum testSOF_byte = 0;
	enum testSOF_offset = 0;
	enum testSOF_position = Position(0, 0);

	enum testEOF_byte = 872;
	enum testEOF_offset = 805;
	enum testEOF_position = Position(36, 1);

	// in line before unicode
	enum testLinePreUni_byte = 757;
	enum testLinePreUni_offset = 724;
	enum testLinePreUni_position = Position(29, 4); // after `//`

	// in line after unicode
	enum testLinePostUni_byte = 789;
	enum testLinePostUni_offset = 742;
	enum testLinePostUni_position = Position(29, 22); // after `purple” 在`

	// ascii line after unicode line
	enum testMidAsciiLine_byte = 804;
	enum testMidAsciiLine_offset = 753;
	enum testMidAsciiLine_position = Position(31, 7);

	@("{offset, bytes, position} -> {offset, bytes, position}")
	unittest
	{
		import std.conv;
		import std.stdio;

		static foreach (test; [
				"SOF", "EOF", "LinePreUni", "LinePostUni", "MidAsciiLine"
			])
		{
			{
				enum testOffset = mixin("test" ~ test ~ "_offset");
				enum testByte = mixin("test" ~ test ~ "_byte");
				enum testPosition = mixin("test" ~ test ~ "_position");

				writeln(" === Test ", test, " ===");

				writeln(testByte, " byte -> offset ", testOffset);
				assert(testUnicodeDocument.bytesToOffset(testByte) == testOffset,
						"fail " ~ test ~ " byte->offset = " ~ testUnicodeDocument.bytesToOffset(testByte)
						.to!string);
				writeln(testByte, " byte -> position ", testPosition);
				assert(testUnicodeDocument.bytesToPosition(testByte) == testPosition,
						"fail " ~ test ~ " byte->position = " ~ testUnicodeDocument.bytesToPosition(testByte)
						.to!string);

				writeln(testOffset, " offset -> byte ", testByte);
				assert(testUnicodeDocument.offsetToBytes(testOffset) == testByte,
						"fail " ~ test ~ " offset->byte = " ~ testUnicodeDocument.offsetToBytes(testOffset)
						.to!string);
				writeln(testOffset, " offset -> position ", testPosition);
				assert(testUnicodeDocument.offsetToPosition(testOffset) == testPosition,
						"fail " ~ test ~ " offset->position = " ~ testUnicodeDocument.offsetToPosition(testOffset)
						.to!string);

				writeln(testPosition, " position -> offset ", testOffset);
				assert(testUnicodeDocument.positionToOffset(testPosition) == testOffset,
						"fail " ~ test ~ " position->offset = " ~ testUnicodeDocument.positionToOffset(testPosition)
						.to!string);
				writeln(testPosition, " position -> byte ", testByte);
				assert(testUnicodeDocument.positionToBytes(testPosition) == testByte,
						"fail " ~ test ~ " position->byte = " ~ testUnicodeDocument.positionToBytes(testPosition)
						.to!string);

				writeln();
			}
		}

		const size_t maxBytes = testEOF_byte;
		const size_t maxOffset = testEOF_offset;
		const Position maxPosition = testEOF_position;

		writeln("max offset -> byte");
		assert(testUnicodeDocument.offsetToBytes(size_t.max) == maxBytes);
		writeln("max offset -> position");
		assert(testUnicodeDocument.offsetToPosition(size_t.max) == maxPosition);
		writeln("max byte -> offset");
		assert(testUnicodeDocument.bytesToOffset(size_t.max) == maxOffset);
		writeln("max byte -> position");
		assert(testUnicodeDocument.bytesToPosition(size_t.max) == maxPosition);
		writeln("max position -> offset");
		assert(testUnicodeDocument.positionToOffset(Position(uint.max, uint.max)) == maxOffset);
		writeln("max position -> byte");
		assert(testUnicodeDocument.positionToBytes(Position(uint.max, uint.max)) == maxBytes);
	}

	@("character transform benchmarks")
	unittest
	{
		import std.datetime.stopwatch;
		import std.random;
		import std.stdio;

		enum PositionCount = 32;
		size_t[PositionCount] testBytes;
		size_t[PositionCount] testOffsets;
		Position[PositionCount] testPositions;

		size_t lengthUtf16 = testUnicodeDocument.text.codeLength!wchar;

		foreach (i, ref v; testOffsets)
		{
			v = uniform(0, lengthUtf16);
			testBytes[i] = testUnicodeDocument.offsetToBytes(v);
			testPositions[i] = testUnicodeDocument.offsetToPosition(v);
		}

		StopWatch sw;
		static foreach (iterations; [1e2, 1e3, 1e4, 1e5])
		{
			writeln("==================");
			writeln("Timing ", iterations, "x", PositionCount, " iterations:");
			static foreach (fun; [
					"offsetToBytes", "offsetToPosition", "bytesToOffset",
					"bytesToPosition", "positionToOffset", "positionToBytes"
				])
			{
				sw.reset();
				sw.start();
				foreach (i; 0 .. iterations)
				{
					foreach (v; 0 .. PositionCount)
					{
						static if (fun[0] == 'b')
							mixin("testUnicodeDocument." ~ fun ~ "(testBytes[v]);");
						else static if (fun[0] == 'o')
							mixin("testUnicodeDocument." ~ fun ~ "(testOffsets[v]);");
						else static if (fun[0] == 'p')
							mixin("testUnicodeDocument." ~ fun ~ "(testPositions[v]);");
						else
							static assert(false);
					}
				}
				sw.stop();
				writeln(fun, ": ", sw.peek);
			}
			writeln();
			writeln();
		}
	}
}
