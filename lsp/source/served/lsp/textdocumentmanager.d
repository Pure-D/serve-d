module served.lsp.textdocumentmanager;

import std.algorithm;
import std.experimental.logger;
import std.json;
import std.string;
import std.utf : codeLength, decode, UseReplacementDchar;

import served.lsp.jsonrpc;
import served.lsp.protocol;

import painlessjson;

/// in-memory representation of a file at any given URI. Not thread-safe.
struct Document
{
	/// The URI of this document. Should not be changed.
	DocumentUri uri;
	/// The language ID as reported by the client. Should not be changed.
	string languageId;
	/// The document version as reported by the client. Should not be changed.
	long version_;
	private char[] text;

	string getLanguageId() const @property @trusted @nogc nothrow
	{
		if (!languageId.length)
		{
			import std.path : extension;
			import std.uni : sicmp;

			const ext = uri.extension;
			if (ext.sicmp(".d") == 0)
				return "d";
			else if (ext.sicmp(".dpp") == 0)
				return "dpp";
			else if (ext.sicmp(".ds") == 0 || ext.sicmp(".dscript") == 0)
				return "dscript";
			else if (ext.sicmp(".dml") == 0)
				return "dml";
			else if (ext.sicmp(".sdl") == 0)
				return "sdl";
			else if (ext.sicmp(".dt") == 0)
				return "diet";
			else
				return null;
		}

		return languageId;
	}

	/// Creates a new D document at the given document URI, with version 0 and
	/// no text.
	this(DocumentUri uri)
	{
		this.uri = uri;
		languageId = "d";
		version_ = 0;
		text = null;
	}

	/// Creates a new document at the given document URI, with the given version
	/// and language and creates a copy of the text to use.
	this(TextDocumentItem doc)
	{
		uri = doc.uri;
		languageId = doc.languageId;
		version_ = doc.version_;
		text = doc.text.dup;
	}

	/// Creates a document with no URI and no language ID and copies the content
	/// into the text buffer using $(LREF setContent).
	static Document nullDocument(scope const(char)[] content)
	{
		Document ret;
		ret.setContent(content);
		return ret;
	}

	immutable(Document) clone()
	{
		Document ret = this;
		ret.text = text.dup;
		return cast(immutable) ret;
	}

	version (unittest) private static Document nullDocumentOwnMemory(char[] content)
	{
		Document ret;
		ret.text = content;
		return ret;
	}

	/// Returns a read-only view of the text. The text may however be changed
	/// by other operations, so this slice should be used directly and not after
	/// any context yield or API call potentially modifying the data.
	const(char)[] rawText() const
	{
		return cast(const(char)[]) text;
	}

	string rawText() immutable
	{
		return text;
	}

	///
	size_t length() const @property
	{
		return text.length;
	}

	/// Sets the content of this document to the given content. Copies the data
	/// from newContent into this text buffer.
	///
	/// Should not be called as an API unless managing some kind of virtual
	/// document manually.
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

	///
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

	/// Converts an LSP offset to a byte offset for using for example in array
	/// slicing.
	size_t offsetToBytes(size_t offset) const
	{
		return .countBytesUntilUTF16Index(text, offset);
	}

	/// Converts a byte offset to an LSP offset.
	size_t bytesToOffset(size_t bytes) const
	{
		return .countUTF16Length(text[0 .. min($, bytes)]);
	}

	/// Converts a line/column position to an LSP offset.
	size_t positionToOffset(Position position) const
	{
		size_t offset = 0;
		size_t bytes = 0;
		while (bytes < text.length && position.line > 0)
		{
			const c = text.ptr[bytes];
			if (c == '\n')
				position.line--;
			utf16DecodeUtf8Length(c, offset, bytes);
		}

		while (bytes < text.length && position.character > 0)
		{
			const c = text.ptr[bytes];
			if (c == '\n')
				break;
			size_t utf16Size;
			utf16DecodeUtf8Length(c, utf16Size, bytes);
			if (utf16Size < position.character)
				position.character -= utf16Size;
			else
				position.character = 0;
			offset += utf16Size;
		}
		return offset;
	}

	/// Converts a line/column position to a byte offset.
	size_t positionToBytes(Position position) const
	{
		size_t index = 0;
		while (index < text.length && position.line > 0)
			if (text.ptr[index++] == '\n')
				position.line--;

		while (index < text.length && position.character > 0)
		{
			const c = text.ptr[index];
			if (c == '\n')
				break;
			size_t utf16Size;
			utf16DecodeUtf8Length(c, utf16Size, index);
			if (utf16Size < position.character)
				position.character -= utf16Size;
			else
				position.character = 0;
		}
		return index;
	}

	/// Converts an LSP offset to a line/column position.
	Position offsetToPosition(size_t offset) const
	{
		size_t bytes;
		size_t index;
		size_t lastNl = -1;

		Position ret;
		while (bytes < text.length && index < offset)
		{
			const c = text.ptr[bytes];
			if (c == '\n')
			{
				ret.line++;
				lastNl = index;
			}
			utf16DecodeUtf8Length(c, index, bytes);
		}
		const start = lastNl + 1;
		ret.character = cast(uint)(index - start);
		return ret;
	}

	/// Converts a byte offset to a line/column position.
	Position bytesToPosition(size_t bytes) const
	{
		if (bytes > text.length)
			bytes = text.length;
		auto part = text.ptr[0 .. bytes].representation;
		size_t lastNl = -1;
		Position ret;
		foreach (i; 0 .. bytes)
		{
			if (part.ptr[i] == '\n')
			{
				ret.line++;
				lastNl = i;
			}
		}
		ret.character = cast(uint)(cast(const(char)[]) part[lastNl + 1 .. $]).countUTF16Length;
		return ret;
	}

	/// Converts a line/column byte offset to a line/column position.
	Position lineColumnBytesToPosition(uint line, uint column) const
	{
		scope lineText = lineAtScope(line);
		uint offset = 0;
		// keep over-extending positions
		if (column > lineText.length)
		{
			offset = column - cast(uint)lineText.length;
			column -= offset;
			assert(column <= lineText.length);
		}
		return Position(line, cast(uint) lineText[0 .. column].countUTF16Length + offset);
	}

	/// Returns the position at "end" starting from the given "src" position which is assumed to be at byte "start"
	/// Faster to quickly calculate nearby positions of known byte positions.
	/// Falls back to $(LREF bytesToPosition) if end is before start.
	Position movePositionBytes(Position src, size_t start, size_t end) const
	{
		if (end == start)
			return src;
		if (end < start)
			return bytesToPosition(end);

		auto t = text[min($, start) .. min($, end)];
		size_t bytes;
		while (bytes < t.length)
		{
			const c = t.ptr[bytes];
			if (c == '\n')
			{
				src.line++;
				src.character = 0;
				bytes++;
			}
			else
				utf16DecodeUtf8Length(c, src.character, bytes);
		}
		return src;
	}

	Position nextPositionBytes(ref Position src, ref size_t start, size_t end) const
	{
		auto pos = movePositionBytes(src, start, end);
		src = pos;
		start = end;
		return pos;
	}

	/// Returns the word range at a given line/column position.
	TextRange wordRangeAt(Position position) const
	{
		auto chars = wordInLine(lineAtScope(position), position.character);
		return TextRange(Position(position.line, chars[0]), Position(position.line, chars[1]));
	}

	/// Returns the word range at a given byte position.
	size_t[2] wordRangeAt(size_t bytes) const
	{
		auto lineStart = text.lastIndexOf('\n', bytes) + 1;
		auto ret = wordInLineBytes(text[lineStart .. $], cast(uint)(bytes - lineStart));
		ret[0] += lineStart;
		ret[1] += lineStart;
		return ret;
	}

	/// Returns a byte offset range as `[start, end]` of the given 0-based line
	/// number.
	size_t[2] lineByteRangeAt(uint line) const
	{
		size_t start = 0;
		size_t index = 0;
		while (line > 0 && index < text.length)
		{
			const c = text.ptr[index++];
			if (c == '\n')
			{
				line--;
				start = index;
			}
		}
		// if !found
		if (line != 0)
			return [0, 0];

		auto end = text.indexOf('\n', start);
		if (end == -1)
			end = text.length;
		else
			end++;

		return [start, end];
	}

	/// Returns the text of a line at the given position.
	string lineAt(Position position) const
	{
		return lineAt(position.line);
	}

	/// Returns the text of a line starting at line 0.
	string lineAt(uint line) const
	{
		return lineAtScope(line).idup;
	}

	/// Returns the line text which is only in this scope if text isn't modified
	/// See_Also: $(LREF lineAt)
	scope const(char)[] lineAtScope(Position position) const
	{
		return lineAtScope(position.line);
	}

	/// Returns the line text which is only in this scope if text isn't modified
	/// See_Also: $(LREF lineAt)
	scope const(char)[] lineAtScope(uint line) const
	{
		auto range = lineByteRangeAt(line);
		return text[range[0] .. range[1]];
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

	/// Returns how a line is terminated at the given 0-based line number.
	EolType eolAt(int line) const
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

/// Helper struct which should have one unique instance in the application which
/// processes document events sent by a LSP client to an LSP server and creates
/// an in-memory representation of all the files managed by the client.
struct TextDocumentManager
{
	/// Internal document storage. Only iterate over this using `foreach`, other
	/// operations are not considered officially supported.
	Document[] documentStore;

	/// Same as $(LREF tryGet) but throws an exception if the URI doesn't exist.
	ref Document opIndex(string uri)
	{
		auto idx = documentStore.countUntil!(a => a.uri == uri);
		if (idx == -1)
			throw new Exception("Document '" ~ uri ~ "' not found");
		return documentStore[idx];
	}

	/// Tries to get a document from a URI, returns Document.init if it is not
	/// in the in-memory cache / not sent by the client.
	Document tryGet(string uri)
	{
		auto idx = documentStore.countUntil!(a => a.uri == uri);
		if (idx == -1)
			return Document.init;
		return documentStore[idx];
	}

	/// Tries to load a given URI manually without having it received via LSP
	/// methods. Note that a LSP close method will unload this early.
	/// Returns: the created document
	/// Throws: FileException in case the file doesn't exist or other file
	///         system errors. In this case no new document should have been
	///         inserted yet.
	ref Document loadFromFilesystem(string uri)
	{
		import served.lsp.uri : uriToFile;
		import fs = std.file;

		string path = uriToFile(uri);
		auto content = fs.readText(path);

		auto index = documentStore.length++;
		documentStore[index].uri = uri;
		documentStore[index].version_ = -1;
		documentStore[index].setContent(content);
		return documentStore[index];
	}

	/// Tries to get a document from a URI, returns Document.init if it is not
	/// in the in-memory cache / not sent by the client.
	/// Throws: FileException in case the file doesn't exist or other file
	///         system errors. In this case no new document should have been
	///         inserted yet.
	ref Document getOrFromFilesystem(string uri)
	{
		auto idx = documentStore.countUntil!(a => a.uri == uri);
		if (idx == -1)
			return loadFromFilesystem(uri);
		else
			return documentStore[idx];
	}

	/// Unloads the given URI so it's no longer accessible. Note that this
	/// should only be done for documents loaded manually and never for LSP
	/// documents as it will break all features in that file until reopened.
	bool unloadDocument(string uri)
	{
		auto idx = documentStore.countUntil!(a => a.uri == uri);
		if (idx == -1)
			return false;

		documentStore[idx] = documentStore[$ - 1];
		documentStore.length--;
		return true;
	}

	/// Returns the currently preferred syncKind to use with the client.
	/// Additionally always supports the `full` sync kind.
	static TextDocumentSyncKind syncKind()
	{
		return TextDocumentSyncKind.incremental;
	}

	/// Processes an LSP packet and performs the document update in-memory that
	/// is requested.
	/// Params:
	///   msg = The request sent by a client. This method only processes
	///     `textDocument/` messages which are relevant to file modification.
	/// Returns: `true` if the given method was handled, `false` otherwise.
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
			if (!unloadDocument(targetUri))
			{
				warning("Received didClose notification for URI not in system: ", targetUri);
				warning("This can be a potential memory leak if it was previously opened under a different name.");
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

/// Helper structure for storing any data of type T on a per-file basis.
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
uint[2] wordInLine(const(char)[] line, uint character)
{
	return wordInLineImpl!(wchar, uint)(line, character);
}

/// ditto
size_t[2] wordInLineBytes(const(char)[] line, size_t bytes)
{
	return wordInLineImpl!(char, size_t)(line, bytes);
}

SizeT[2] wordInLineImpl(CharT, SizeT)(const(char)[] line, SizeT character)
{
	size_t index = 0;
	SizeT offs = 0;

	SizeT lastStart = character;
	SizeT start = character, end = character + 1;
	bool searchStart = true;

	while (index < line.length)
	{
		const c = decode(line, index);
		const l = cast(SizeT) c.codeLength!CharT;

		if (searchStart)
		{
			if (isDIdentifierSeparatingChar(c))
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
			if (isDIdentifierSeparatingChar(c))
				break;
		}
	}

	if (start > line.length)
		start = cast(SizeT)line.length;
	if (end > line.length)
		end = cast(SizeT)line.length;
	if (end < start)
		end = start;

	return [start, end];
}

deprecated("use isDIdentifierSeparatingChar instead")
alias isIdentifierSeparatingChar = isDIdentifierSeparatingChar;

///
bool isDIdentifierSeparatingChar(dchar c)
{
	return c < 48 || (c > 57 && c < 65) || c == '[' || c == '\\' || c == ']'
		|| c == '`' || (c > 122 && c < 128) || c == '\u2028' || c == '\u2029'; // line separators
}

///
bool isValidDIdentifier(const(char)[] s)
{
	import std.ascii : isDigit;

	return s.length && !s[0].isDigit && !s.any!isDIdentifierSeparatingChar;
}

unittest
{
	assert(!isValidDIdentifier(""));
	assert(!isValidDIdentifier("0"));
	assert(!isValidDIdentifier("10"));
	assert(!isValidDIdentifier("1a"));
	assert(isValidDIdentifier("_"));
	assert(isValidDIdentifier("a"));
	assert(isValidDIdentifier("__helloWorld123"));
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

pragma(inline, true) private void utf16DecodeUtf8Length(A, B)(char c, ref A utf16Index,
		ref B utf8Index) @safe nothrow @nogc
{
	switch (c & 0b1111_0000)
	{
	case 0b1110_0000:
		// assume valid encoding (no wrong surrogates)
		utf16Index++;
		utf8Index += 3;
		break;
	case 0b1111_0000:
		utf16Index += 2;
		utf8Index += 4;
		break;
	case 0b1100_0000:
	case 0b1101_0000:
		utf16Index++;
		utf8Index += 2;
		break;
	default:
		utf16Index++;
		utf8Index++;
		break;
	}
}

pragma(inline, true) size_t countUTF16Length(scope const(char)[] text) @safe nothrow @nogc
{
	size_t offset;
	size_t index;
	while (index < text.length)
	{
		const c = (() @trusted => text.ptr[index++])();
		if (cast(byte)c >= -0x40) offset++;
		if (c >= 0xf0) offset++;
	}
	return offset;
}

pragma(inline, true) size_t countBytesUntilUTF16Index(scope const(char)[] text, size_t utf16Offset) @safe nothrow @nogc
{
	size_t bytes;
	size_t offset;
	while (offset < utf16Offset && bytes < text.length)
	{
		char c = (() @trusted => text.ptr[bytes++])();
		if (cast(byte)c >= -0x40) offset++;
		if (c >= 0xf0) offset++;
	}
	while (bytes < text.length)
	{
		char c = (() @trusted => text.ptr[bytes])();
		if (cast(byte)c >= -0x40) break;
		bytes++;
	}
	return bytes;
}

version (unittest)
{
	import core.time;

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

	version (none)
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

		static immutable funs = [
			"offsetToBytes", "offsetToPosition", "bytesToOffset", "bytesToPosition",
			"positionToOffset", "positionToBytes"
		];

		size_t debugSum;

		size_t lengthUtf16 = testUnicodeDocument.text.codeLength!wchar;
		enum TestRepeats = 10;
		Duration[TestRepeats][funs.length] times;

		StopWatch sw;
		static foreach (iterations; [
				1e3, 1e4, /* 1e5 */
			])
		{
			writeln("==================");
			writeln("Timing ", iterations, "x", PositionCount, "x", TestRepeats, " iterations:");
			foreach (ref row; times)
				foreach (ref col; row)
					col = Duration.zero;

			static foreach (t; 0 .. TestRepeats)
			{
				foreach (i, ref v; testOffsets)
				{
					v = uniform(0, lengthUtf16);
					testBytes[i] = testUnicodeDocument.offsetToBytes(v);
					testPositions[i] = testUnicodeDocument.offsetToPosition(v);
				}
				static foreach (fi, fun; funs)
				{
					sw.reset();
					sw.start();
					foreach (i; 0 .. iterations)
					{
						foreach (v; 0 .. PositionCount)
						{
							static if (fun[0] == 'b')
								mixin("debugSum |= testUnicodeDocument." ~ fun ~ "(testBytes[v]).sumVal;");
							else static if (fun[0] == 'o')
								mixin("debugSum |= testUnicodeDocument." ~ fun ~ "(testOffsets[v]).sumVal;");
							else static if (fun[0] == 'p')
								mixin("debugSum |= testUnicodeDocument." ~ fun ~ "(testPositions[v]).sumVal;");
							else
								static assert(false);
						}
					}
					sw.stop();
					times[fi][t] = sw.peek;
				}
			}
			static foreach (fi, fun; funs)
			{
				writeln(fun, ": ", formatDurationDistribution(times[fi]));
			}
			writeln();
			writeln();
		}

		writeln("tricking the optimizer", debugSum);
	}

	private pragma(inline, true) size_t sumVal(size_t v) pure @safe nothrow @nogc
	{
		return v;
	}

	private pragma(inline, true) size_t sumVal(Position v) pure @trusted nothrow @nogc
	{
		return cast(size_t)*(cast(ulong*)&v);
	}

	private string formatDurationDistribution(size_t n)(Duration[n] durs)
	{
		import std.algorithm : fold, map, sort, sum;
		import std.format : format;
		import std.math : sqrt;

		Duration total = durs[].fold!"a+b";
		sort!"a<b"(durs[]);
		double msAvg = cast(double) total.total!"hnsecs" / 10_000.0 / n;
		double msMedian = cast(double) durs[$ / 2].total!"hnsecs" / 10_000.0;
		double[n] diffs = 0;
		foreach (i, dur; durs)
			diffs[i] = (cast(double) dur.total!"hnsecs" / 10_000.0) - msAvg;
		double msStdDeviation = diffs[].map!"a*a".sum.sqrt;
		return format!"[avg=%.4fms, median=%.4f, sd=%.4f]"(msAvg, msMedian, msStdDeviation);
	}
}
