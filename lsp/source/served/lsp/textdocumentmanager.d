module served.lsp.textdocumentmanager;

import std.algorithm;
import std.experimental.logger;
import std.json;
import std.string;
import std.utf : codeLength, decode, UseReplacementDchar;

import served.lsp.jsonrpc;
import served.lsp.protocol;

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

	/// Returns the language ID or guesses it given the filename's extension.
	/// Returns null if none is set and can't be guessed.
	///
	/// Guessing Map:
	/// * `.d|.di` = `"d"`
	/// * `.dpp` = `"dpp"`
	/// * `.c` = `"c"`
	/// * `.cpp` = `"cpp"`
	/// * `.ds|.dscript` = `"dscript"`
	/// * `.dml` = `"dml"`
	/// * `.sdl` = `"sdl"`
	/// * `.dt` = `"diet"`
	/// * `.json` = `"json"`
	string getLanguageId() const @property @trusted @nogc nothrow
	{
		if (!languageId.length)
		{
			import std.path : extension;
			import std.uni : sicmp;

			const ext = uri.extension;
			if (ext.sicmp(".d") == 0 || ext.sicmp(".di") == 0)
				return "d";
			else if (ext.sicmp(".dpp") == 0)
				return "dpp";
			else if (ext.sicmp(".c") == 0)
				return "c";
			else if (ext.sicmp(".cpp") == 0)
				return "cpp";
			else if (ext.sicmp(".ds") == 0 || ext.sicmp(".dscript") == 0)
				return "dscript";
			else if (ext.sicmp(".dml") == 0)
				return "dml";
			else if (ext.sicmp(".sdl") == 0)
				return "sdl";
			else if (ext.sicmp(".dt") == 0)
				return "diet";
			else if (ext.sicmp(".json") == 0)
				return "json";
			else
				return null;
		}

		return languageId;
	}

	///
	unittest
	{
		Document d;
		assert(d.getLanguageId == null);
		d.uri = "file:///home/project/app.d";
		assert(d.getLanguageId == "d");
		d.languageId = "cpp";
		assert(d.getLanguageId == "cpp");
	}

	/// Creates a new document at the given document URI, with version 0 and
	/// no text and guessed language ID. See $(LREF getLanguageId)
	this(DocumentUri uri)
	{
		this.uri = uri;
		languageId = getLanguageId;
		version_ = 0;
		text = null;
	}

	///
	unittest
	{
		auto doc = Document("file:///home/projects/app.d");
		assert(doc.uri == "file:///home/projects/app.d");
		assert(doc.languageId == "d");
		assert(doc.version_ == 0);
		assert(!doc.rawText.length);
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

	///
	unittest
	{
		// e.g. received from LSP client
		TextDocumentItem item = {
			uri: "file:///home/projects/app.c",
			languageId: "cpp",
			version_: 0,
			text: "#include <stdio>",
		};
		auto doc = Document(item);
		assert(doc.length == "#include <stdio>".length);
	}

	/// Creates a document with no URI and no language ID and copies the content
	/// into the text buffer using $(LREF setContent).
	static Document nullDocument(scope const(char)[] content)
	{
		Document ret;
		ret.setContent(content);
		return ret;
	}

	///
	unittest
	{
		auto doc = Document.nullDocument(`import std.stdio;`);
		assert(!doc.languageId.length);
		assert(doc.version_ == 0);
		assert(!doc.uri.length);
		assert(doc.rawText == "import std.stdio;");
	}

	/// Returns a copy of this document with the text memory duplicated.
	/// May safely be cast to immutable.
	Document clone() const
	{
		Document ret;
		ret.uri = uri;
		ret.version_ = version_;
		ret.languageId = languageId;
		ret.text = text.dup;
		return ret;
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
	///
	/// If used on an immutable Document, the text cannot be changed and thus
	/// returns a full string instead of a const(char)[] slice.
	const(char)[] rawText() const
	{
		return text;
	}

	/// ditto
	string rawText() immutable
	{
		return text;
	}

	/// Returns the text length.
	size_t length() const @property
	{
		return text.length;
	}

	/// Sets the content of this document to the given content. Copies the data
	/// from newContent into this text buffer.
	///
	/// Should not be called as an API unless managing some kind of virtual
	/// document manually.
	ref typeof(this) setContent(scope const(char)[] newContent) return
	{
		if (newContent.length < text.length)
		{
			text.ptr[0 .. newContent.length] = newContent;
			text.ptr[newContent.length] = '\0'; // insert null byte to find corruptions
			text.length = newContent.length;
			text = text.assumeSafeAppend;
		}
		else
		{
			text = text.assumeSafeAppend;
			text.length = newContent.length;
			text[0 .. $] = newContent;
		}
		return this;
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
		scope lineText = lineAtScope(line).chomp();
		uint offset = 0;
		// keep over-extending positions
		if (column > lineText.length)
		{
			offset = column - cast(uint)lineText.length;
			column = cast(uint)lineText.length;
		}
		// utf16 length is always gonna be less than byte length, so adding offset will never overflow
		return Position(line, cast(uint)lineText[0 .. column].countUTF16Length + offset);
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

		auto t = text.ptr[min(text.length, start) .. min(text.length, end)];
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

	///
	unittest
	{
		import std.regex;

		auto intRegex = regex(`\bint\b`);

		Document d;
		d.setContent("int foo(int x, uint y)\n{\n    return cast(int)(x + y);\n}\n");

		// either use size_t.max or 0, both work as starting points for different reasons:
		// - 0 always matches Position.init, so the offset can be calculated
		// - size_t.max is larger than the checked index match, so position is recomputed
		size_t lastIndex = size_t.max;
		Position lastPosition;

		Position[] matches;

		foreach (match; d.rawText.matchAll(intRegex))
		{
			size_t index = match.pre.length;
			// to reduce boilerplate, use d.nextPositionBytes instead!
			auto pos = d.movePositionBytes(lastPosition, lastIndex, index);
			lastIndex = index;
			lastPosition = pos;
			matches ~= pos;
		}

		assert(matches == [
			Position(0, 0),
			Position(0, 8),
			Position(2, 16)
		]);
	}

	/// Calls $(LREF movePositionBytes), updates src to be the return value and
	/// updates start to become end. This reduces boilerplate in common calling
	/// scenarios.
	Position nextPositionBytes(ref Position src, ref size_t start, size_t end) const
	{
		auto pos = movePositionBytes(src, start, end);
		src = pos;
		start = end;
		return pos;
	}

	///
	unittest
	{
		import std.regex;

		auto intRegex = regex(`\bint\b`);

		Document d;
		d.setContent("int foo(int x, uint y)\n{\n    return cast(int)(x + y);\n}\n");

		size_t lastIndex = size_t.max;
		Position lastPosition;

		Position[] matches;
		foreach (match; d.rawText.matchAll(intRegex))
			matches ~= d.nextPositionBytes(lastPosition, lastIndex, match.pre.length);

		assert(matches == [
			Position(0, 0),
			Position(0, 8),
			Position(2, 16)
		]);
	}

	/// Returns the word range at a given line/column position.
	TextRange wordRangeAt(Position position) const
	{
		auto chars = wordInLine(lineAtScope(position), position.character);
		return TextRange(Position(position.line, chars[0]), Position(position.line, chars[1]));
	}

	///
	unittest
	{
		Document d;
		d.setContent(`void main() { writeln("hello world"); }`);
		assert(d.wordRangeAt(Position(0, 0)) == TextRange(0, 0, 0, 4));
	}

	/// Returns the word range at a given byte position.
	size_t[2] wordRangeAt(size_t bytes) const
	{
		auto lineStart = text.lastIndexOf('\n', bytes) + 1;
		auto ret = wordInLineBytes(
			text.ptr[lineStart .. text.length],
			cast(uint)(bytes - lineStart));
		ret[0] += lineStart;
		ret[1] += lineStart;
		return ret;
	}

	///
	unittest
	{
		Document d;
		d.setContent(`void main() { writeln("hello world"); }`);
		assert(d.wordRangeAt(0) == [0, 4]);
		assert(d.wordRangeAt(3) == [0, 4]);
		assert(d.wordRangeAt(4) == [0, 4]);
		assert(d.wordRangeAt(5) == [5, 9]);
		assert(d.wordRangeAt(9) == [5, 9]);
		assert(d.wordRangeAt(10) == [10, 10]);
		assert(d.wordRangeAt(14) == [14, 21]);
		assert(d.wordRangeAt(20) == [14, 21]);
		assert(d.wordRangeAt(21) == [14, 21]);
		assert(d.wordRangeAt(23) == [23, 28]);
		assert(d.wordRangeAt(27) == [23, 28]);
		assert(d.wordRangeAt(28) == [23, 28]);
		assert(d.wordRangeAt(29) == [29, 34]);
		assert(d.wordRangeAt(30) == [29, 34]);
		assert(d.wordRangeAt(34) == [29, 34]);
	}

	/// Returns a byte offset range as `[start, end]` of the given 0-based line
	/// number. Contains the line terminator, if it exists.
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
	///
	/// Contains the line terminator, if it exists.
	///
	/// The overload taking in a position just calls the overload taking a line
	/// with the line being the position's line.
	string lineAt(Position position) const
	{
		return lineAt(position.line);
	}

	/// ditto
	string lineAt(Position position) immutable
	{
		return lineAt(position.line);
	}

	/// Returns the text of a line starting at line 0.
	///
	/// Contains the line terminator, if it exists.
	string lineAt(uint line) const
	{
		return lineAtScope(line).idup;
	}

	/// ditto
	string lineAt(uint line) immutable
	{
		return lineAtScope(line);
	}

	///
	unittest
	{
		Document d = Document("file:///home/projects/app.d");
		d.setContent("im");

		immutable d2 = cast(immutable)d.clone.setContent("import std.stdio;\nvoid main() {}");

		static assert(is(typeof(d.lineAtScope(0)) == const(char)[]));
		static assert(is(typeof(d2.lineAtScope(0)) == string));
		static assert(is(typeof(d.lineAt(0)) == string));
		static assert(is(typeof(d2.lineAt(0)) == string));

		assert(d.lineAt(0) == "im");
		assert(d2.lineAt(0) == "import std.stdio;\n");

		assert(d.lineAtScope(0) == "im");
		assert(d2.lineAtScope(0) == "import std.stdio;\n");

		assert(d.lineAt(0).ptr !is d.rawText.ptr);
		assert(d2.lineAt(0).ptr is d2.rawText.ptr);
	}

	/// Returns the line text at the given position. The memory content may be
	/// modified by the $(LREF setContent) method by other code in the same
	/// context or in a different context.
	///
	/// The overload taking in a position just calls the overload taking a line
	/// with the line being the position's line.
	///
	/// Contains the line terminator, if it exists.
	///
	/// See_Also: $(LREF lineAt) to get the same content, but with duplicated
	/// memory, so it can be stored for later use.
	scope auto lineAtScope(Position position) const inout
	{
		return lineAtScope(position.line);
	}

	/// ditto
	scope auto lineAtScope(uint line) const inout
	{
		auto range = lineByteRangeAt(line);
		return text[range[0] .. range[1]];
	}

	///
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
	/// Defaults to LF for the last line / no line terminator.
	EolType eolAt(int line) const
	{
		size_t index = 0;
		int curLine = 0;
		bool prevWasCr = false;
		while (index < text.length)
		{
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

	///
	unittest
	{
		auto d = Document("file:///home/projects/app.d");
		d.setContent("import std.stdio;\nvoid main() {\r\n\twriteln(`hello world`);\r}");
		// \r is not supported as line terminator
		assert(d.lineAt(2) == "\twriteln(`hello world`);\r}");

		assert(d.eolAt(0) == EolType.lf);
		assert(d.eolAt(1) == EolType.crlf);
		assert(d.eolAt(2) == EolType.lf);
	}
}

/// Helper struct which should have one unique instance in the application which
/// processes document events sent by a LSP client to an LSP server and creates
/// an in-memory representation of all the files managed by the client.
///
/// This data structure is not thread safe.
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

	deprecated ref Document loadFromFilesystem()(string uri)
	{
		static assert(false, "use getOrFromFilesystem instead (LSP open takes priority over filesystem)");
	}

	/// Returns the managed document for the given URI or if it doesn't exist
	/// it tries to read the file from the filesystem and open it from that.
	///
	/// Note that a LSP close method will unload this early.
	///
	/// Params:
	///     uri = the document URI to try to load. Must be consistent with LSP
	///           URIs. (e.g. normalized URIs)
	///     inserted = if specified, gets set to true if the file was read from
	///                filesystem and false if it was already present.
	///
	/// Returns: the created document
	///
	/// Throws: FileException in case the file doesn't exist or other file
	///         system errors. In this case no new document should have been
	///         inserted yet.
	ref Document getOrFromFilesystem(string uri, out bool inserted)
	{
		import served.lsp.uri : uriToFile;
		import fs = std.file;

		auto idx = documentStore.countUntil!(a => a.uri == uri);
		if (idx != -1)
		{
			inserted = false;
			return documentStore[idx];
		}

		string path = uriToFile(uri);
		auto content = fs.readText(path);

		auto index = documentStore.length++;
		documentStore[index].uri = uri;
		documentStore[index].version_ = -1;
		documentStore[index].setContent(content);
		inserted = true;
		return documentStore[index];
	}

	///
	unittest
	{
		import served.lsp.uri;

		import std.file;
		import std.path;

		auto dir = buildPath(tempDir(), "textdocumentmanager");
		mkdir(dir);
		scope (exit)
			rmdirRecurse(dir);

		auto app_d = buildPath(dir, "app.d");
		auto src = "import std.stdio; void main() { writeln(`hello world`); }";
		write(app_d, src);

		TextDocumentManager documents;
		bool created;
		auto doc = &documents.getOrFromFilesystem(uriFromFile(app_d), created);
		assert(created);
		auto other = &documents.getOrFromFilesystem(uriFromFile(app_d));
		assert(doc is other);

		assert(doc.rawText == src);
		assert(doc.rawText !is src);
	}

	/// ditto
	ref Document getOrFromFilesystem(string uri)
	{
		bool b;
		return getOrFromFilesystem(uri, b);
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
		documentStore = documentStore.assumeSafeAppend;
		return true;
	}

	/// Returns the currently preferred syncKind to use with the client.
	/// Additionally always supports the `full` sync kind.
	static TextDocumentSyncKind syncKind()
	{
		return TextDocumentSyncKind.incremental;
	}

	///
	unittest
	{
		assert(TextDocumentManager.syncKind == TextDocumentSyncKind.incremental);
	}

	/// Inserts a document manually or updates an existing one, acting like
	/// textDocument/didOpen if it didn't exist or fully replacing the document
	/// if it did exist.
	ref Document insertOrUpdate(Document d)
	{
		auto idx = documentStore.countUntil!(a => a.uri == d.uri);
		if (idx != -1)
		{
			return documentStore[idx] = d;
		}
		else
		{
			auto index = documentStore.length++;
			return documentStore[index] = d;
		}
	}

	/// Processes an LSP packet and performs the document update in-memory that
	/// is requested.
	/// Params:
	///   msg = The request sent by a client. This method only processes
	///     `textDocument/` messages which are relevant to file modification.
	/// Returns: `true` if the given method was handled, `false` otherwise.
	bool process(RequestMessageRaw msg)
	{
		if (msg.method == "textDocument/didOpen")
		{
			auto params = msg.paramsJson.deserializeJson!DidOpenTextDocumentParams;
			// there may be at most one didOpen request, but library code can
			// load files from the filesystem 
			insertOrUpdate(Document(params.textDocument));
			return true;
		}
		else if (msg.method == "textDocument/didClose")
		{
			auto params = msg.paramsJson.deserializeJson!DidCloseTextDocumentParams;
			auto targetUri = params.textDocument.uri;
			if (!unloadDocument(targetUri))
			{
				warning("Received didClose notification for URI not in system: ", targetUri);
				warning("This can be a potential memory leak if it was previously opened under a different name.");
			}
			return true;
		}
		else if (msg.method == "textDocument/didChange")
		{
			auto params = msg.paramsJson.deserializeJson!DidChangeTextDocumentParams;
			auto targetUri = params.textDocument.uri;
			auto idx = documentStore.countUntil!(a => a.uri == targetUri);
			if (idx >= 0)
			{
				documentStore[idx].version_ = params.textDocument.version_;
				foreach (change; params.contentChanges)
				{
					if (!change.range.isNone)
						documentStore[idx].applyChange(change.range.deref, change.text);
					else
						documentStore[idx].setContent(change.text);
				}
			}
			return true;
		}
		return false;
	}
}

///
unittest
{
	import std.exception;

	TextDocumentManager documents;
	// most common usage, forward LSP events to this helper struct.
	RequestMessageRaw incomingPacket = {
		// dummy data
		method: "textDocument/didOpen",
		paramsJson: `{
			"textDocument": {
				"uri": "file:///home/projects/app.d",
				"languageId": "d",
				"version": 123,
				"text": "import std.stdio;\n\nvoid main()\n{\n\twriteln(\"hello world\");\n}\n"
			}
		}`
	};
	documents.process(incomingPacket);
	// documents.process returns false if it's not a method meant for text
	// document management. serve-d:serverbase abstracts this away automatically.

	// normally used from LSP methods where you have params like this
	TextDocumentPositionParams params = {
		textDocument: TextDocumentIdentifier("file:///home/projects/app.d"),
		position: Position(4, 2)
	};

	// if it's sent by the LSP, the document being loaded should be almost guaranteed.
	auto doc = documents[params.textDocument.uri];
	// trying to index files that haven't been sent by the client will throw an Exception
	assertThrown(documents["file:///path/to/non-registered.d"]);

	// you can use tryGet to see if a Document has been opened yet and use it if so.
	assert(documents.tryGet("file:///path/to/non-registered.d") is Document.init);
	assert(documents.tryGet(params.textDocument.uri) !is Document.init);

	// Document defines a variety of utility functions that have been optimized
	// for speed and convenience.
	assert(doc.lineAtScope(params.position) == "\twriteln(\"hello world\");\n");

	auto range = doc.wordRangeAt(params.position);
	assert(doc.positionToBytes(range.start) == 34);
	assert(doc.positionToBytes(range.end) == 41);

	// when yielding (Fiber context switch) documents may be modified or deleted though:

	RequestMessageRaw incomingPacket2 = {
		// dummy data
		method: "textDocument/didChange",
		paramsJson: `{
			"textDocument": {
				"uri": "file:///home/projects/app.d",
				"version": 124
			},
			"contentChanges": [
				{
					"range": {
						"start": { "line": 4, "character": 6 },
						"end": { "line": 4, "character": 8 }
					},
					"text": ""
				}
			]
		}`
	};
	documents.process(incomingPacket2);

	assert(doc.lineAtScope(params.position) == "\twrite(\"hello world\");\n");

	RequestMessageRaw incomingPacket3 = {
		// dummy data
		method: "textDocument/didChange",
		paramsJson: `{
			"textDocument": {
				"uri": "file:///home/projects/app.d",
				"version": 125
			},
			"contentChanges": [
				{
					"text": "replace everything"
				}
			]
		}`
	};
	documents.process(incomingPacket3);

	// doc.rawText is now half overwritten, you need to refetch a document when yielding or updating:
	assert(doc.rawText != "replace everything");
	doc = documents[params.textDocument.uri];
	assert(doc.rawText == "replace everything");

	RequestMessageRaw incomingPacket4 = {
		// dummy data
		method: "textDocument/didClose",
		paramsJson: `{
			"textDocument": {
				"uri": "file:///home/projects/app.d"
			}
		}`
	};
	documents.process(incomingPacket4);

	assertThrown(documents[params.textDocument.uri]);
	// so make sure that you don't keep references to documents when leaving scope or switching context.
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
out(r; r[1] >= r[0])
{
	size_t index = 0;
	SizeT offs = 0;

	SizeT lastStart = 0;
	SizeT start = character, end = character;
	bool searchStart = true;

	while (index < line.length)
	{
		const c = decode(line, index);
		const l = cast(SizeT) c.codeLength!CharT;

		if (searchStart)
		{
			if (isDIdentifierSeparatingChar(c))
			{
				if (character == 0)
					break;
				lastStart = offs + l;
			}

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

	return [start, end];
}

unittest
{
	string a = "int i;";
	string b = "a (int i;";
	string c = "{int i;";
	string d = "{ int i;";
	assert(a.wordInLineBytes(0) == [0, 3]);
	assert(a.wordInLineBytes(1) == [0, 3]);
	assert(a.wordInLineBytes(2) == [0, 3]);
	assert(a.wordInLineBytes(3) == [0, 3]);
	assert(a.wordInLineBytes(4) == [4, 5]);
	assert(a.wordInLineBytes(5) == [4, 5]);
	assert(a.wordInLineBytes(6) == [6, 6]);
	assert(a.wordInLineBytes(7) == [6, 6]);
	assert(a.wordInLineBytes(size_t.max) == [6, 6]);

	assert(b.wordInLineBytes(0) == [0, 1]);
	assert(b.wordInLineBytes(1) == [0, 1]);
	assert(b.wordInLineBytes(2) == [2, 2]);
	assert(b.wordInLineBytes(3) == [3, 6]);
	assert(b.wordInLineBytes(4) == [3, 6]);
	assert(b.wordInLineBytes(5) == [3, 6]);
	assert(b.wordInLineBytes(6) == [3, 6]);
	assert(b.wordInLineBytes(7) == [7, 8]);
	assert(b.wordInLineBytes(8) == [7, 8]);
	assert(b.wordInLineBytes(9) == [9, 9]);
	assert(b.wordInLineBytes(10) == [9, 9]);
	assert(b.wordInLineBytes(100) == [9, 9]);
	assert(b.wordInLineBytes(size_t.max) == [9, 9]);

	assert(c.wordInLineBytes(0) == [0, 0]);
	assert(c.wordInLineBytes(1) == [1, 4]);
	assert(c.wordInLineBytes(2) == [1, 4]);
	assert(c.wordInLineBytes(3) == [1, 4]);
	assert(c.wordInLineBytes(4) == [1, 4]);
	assert(c.wordInLineBytes(5) == [5, 6]);
	assert(c.wordInLineBytes(6) == [5, 6]);
	assert(c.wordInLineBytes(7) == [7, 7]);
	assert(c.wordInLineBytes(8) == [7, 7]);
	assert(c.wordInLineBytes(size_t.max) == [7, 7]);

	assert(d.wordInLineBytes(0) == [0, 0]);
	assert(d.wordInLineBytes(1) == [1, 1]);
	assert(d.wordInLineBytes(2) == [2, 5]);
	assert(d.wordInLineBytes(3) == [2, 5]);
	assert(d.wordInLineBytes(4) == [2, 5]);
	assert(d.wordInLineBytes(5) == [2, 5]);
	assert(d.wordInLineBytes(6) == [6, 7]);
	assert(d.wordInLineBytes(7) == [6, 7]);
	assert(d.wordInLineBytes(8) == [8, 8]);
	assert(d.wordInLineBytes(9) == [8, 8]);
	assert(d.wordInLineBytes(size_t.max) == [8, 8]);
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

	// after unicode, end of line
	enum testEOLPostUni_byte = 795;
	enum testEOLPostUni_offset = 744;
	enum testEOLPostUni_position = Position(29, 24); // after `purple” 在表中`

	@("{offset, bytes, position} -> {offset, bytes, position}")
	unittest
	{
		import std.conv;
		import std.stdio;

		static foreach (test; [
				"SOF", "EOF", "LinePreUni", "LinePostUni", "MidAsciiLine", "EOLPostUni"
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

	unittest
	{
		// in line after unicode
		foreach (col; cast(uint[])[256, 300, int.max, uint.max])
		{
			assert(testUnicodeDocument.positionToBytes(Position(29, col)) == testEOLPostUni_byte);
			assert(testUnicodeDocument.positionToOffset(Position(29, col)) == testEOLPostUni_offset);
		}

		assert(testUnicodeDocument.lineColumnBytesToPosition(29, 42) == Position(29, 24));
		assert(testUnicodeDocument.lineColumnBytesToPosition(29, 43) == Position(29, 25));
		assert(testUnicodeDocument.lineColumnBytesToPosition(29, 4_000_000_042) == Position(29, 4_000_000_024));
		assert(testUnicodeDocument.lineColumnBytesToPosition(29, uint.max) == Position(29, 4_294_967_277));
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
