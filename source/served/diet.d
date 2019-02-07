module served.diet;

import dietc.lexer;
import dietc.complete;

import vscode = served.protocol;

import ext = served.extension;

import std.path;

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
