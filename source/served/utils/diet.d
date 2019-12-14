module served.utils.diet;

import dietc.complete;
import dietc.lexer;
import dietc.parser;

import vscode = served.lsp.protocol;

import ext = served.extension;
import served.types : documents;

import std.algorithm;
import std.experimental.logger;
import std.path;
import std.string;

DietComplete[string] dietFileCache;

DietComplete updateDietFile(string file, string content)
{
	if (auto existing = file in dietFileCache)
	{
		existing.reparse(content);
		return *existing;
	}
	else
	{
		DietInput input;
		input.file = file;
		input.code = content;
		auto ret = new DietComplete(input, DietComplete.defaultFileProvider(file.dirName));
		dietFileCache[file] = ret;
		return ret;
	}
}

vscode.CompletionItemKind mapToCompletionItemKind(CompletionType type)
{
	final switch (type)
	{
	case CompletionType.none:
		return vscode.CompletionItemKind.text;
	case CompletionType.tag:
		return vscode.CompletionItemKind.keyword;
	case CompletionType.attribute:
		return vscode.CompletionItemKind.property;
	case CompletionType.value:
		return vscode.CompletionItemKind.constant;
	case CompletionType.reference:
		return vscode.CompletionItemKind.reference;
	case CompletionType.cssName:
		return vscode.CompletionItemKind.property;
	case CompletionType.cssValue:
		return vscode.CompletionItemKind.value;
	case CompletionType.d:
		return vscode.CompletionItemKind.snippet;
	case CompletionType.meta:
		return vscode.CompletionItemKind.keyword;
	}
}

void contextExtractD(DietComplete completion, size_t offset, out string code,
		out size_t dOffset, bool extractContext)
{
	string prefix;
	if (completion.parser.root.children.length > 0)
	{
		int i = 0;
		if (auto node = cast(TagNode) completion.parser.root.children[i])
		{
			if (node.name == "extends" && completion.parser.root.children.length > 1)
				i++;
		}

		if (auto comment = cast(HiddenComment) completion.parser.root.children[i])
		{
			string startComment = comment.content.strip;
			info("Have context ", startComment);
			if (startComment.startsWith("context=") && extractContext)
			{
				auto context = startComment["context=".length .. $];
				auto end = context.indexOfAny(" ;,");
				if (end != -1)
					context = context[0 .. end];

				context = context.strip;
				if (!context.endsWith(".d"))
					context ~= ".d";

				auto currentFile = completion.parser.input.file.baseName;

				foreach (doc; documents.documentStore)
				{
					if (doc.uri.endsWith(context))
					{
						auto content = doc.rawText;
						infof("Searching for diet file '%s' in context file '%s'", currentFile, doc.uri);

						auto index = searchDietTemplateUsage(content, currentFile);
						if (index >= 0)
							prefix = content[0 .. index].idup;
						else
							info("Failed finding diet file, error ", index);
						break;
					}
				}

				if (!prefix.length)
				{
					infof("Didn't find any valid context for diet file '%s' when searching for context '%s'",
							currentFile, context);
				}
			}
		}
	}

	extractD(completion, offset, code, dOffset, prefix);
}

ptrdiff_t searchDietTemplateUsage(scope const(char)[] code, scope const(char)[] dietFile)
{
	auto index = code.indexOf(dietFile);
	if (index == -1)
		return -2;

	if (!code[index + dietFile.length .. $].startsWith("\"", "`"))
		return -3;

	auto funcStart = code[0 .. index].lastIndexOfAny(";!(");
	if (funcStart == -1)
		return -4;

	return code[0 .. funcStart].lastIndexOfAny(";\r\n");
}
