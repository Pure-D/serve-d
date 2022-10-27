module workspaced.com.snippets.control_flow;

import workspaced.api;
import workspaced.com.snippets;

import std.algorithm;
import std.conv;
import std.string;

class ControlFlowSnippetProvider : SnippetProvider
{
	Future!(Snippet[]) provideSnippets(scope const WorkspaceD.Instance instance,
			scope const(char)[] file, scope const(char)[] code, int position, const SnippetInfo info)
	{
		Snippet[] res;

		SnippetLevel lastBreakable = info.findInLocalScope(SnippetLevel.loop, SnippetLevel.switch_);

		if (lastBreakable != SnippetLevel.init)
		{
			bool isSwitch = lastBreakable == SnippetLevel.switch_;

			{
				Snippet snp;
				snp.providerId = typeid(this).name;
				snp.id = snp.title = snp.shortcut = "break";
				snp.plain = snp.snippet = "break;";
				snp.documentation = isSwitch
					? "break out of the current switch"
					: "break out of this loop";
				snp.resolved = true;
				snp.unformatted = true;
				res ~= snp;
			}

			if (isSwitch)
			{
				{
					Snippet snp;
					snp.providerId = typeid(this).name;
					snp.id = snp.title = snp.shortcut = "goto case";
					snp.plain = snp.snippet = "goto case;";
					snp.documentation = "Explicit fall-through into the next case or to case with explicitly given value.\n\nReference: https://dlang.org/spec/statement.html#goto-statement";
					snp.resolved = true;
					snp.unformatted = true;
					res ~= snp;
				}
				{
					Snippet snp;
					snp.providerId = typeid(this).name;
					snp.id = snp.title = snp.shortcut = "goto default";
					snp.plain = snp.snippet = "goto default;";
					snp.documentation = "Go to default case.\n\nReference: https://dlang.org/spec/statement.html#goto-statement";
					snp.resolved = true;
					snp.unformatted = true;
					res ~= snp;
				}
				{
					Snippet snp;
					snp.providerId = typeid(this).name;
					snp.id = snp.title = snp.shortcut = "case";
					snp.snippet = "case ${1}:\n\t$0\n\tbreak;";
					snp.documentation = "Defines a case in the current switch-case.\n\nReference: https://dlang.org/spec/statement.html#switch-statement";
					snp.resolved = true;
					snp.unformatted = true;
					res ~= snp;
				}
				{
					Snippet snp;
					snp.providerId = typeid(this).name;
					snp.id = snp.title = snp.shortcut = "case range";
					snp.snippet = "case ${1}: .. case ${2}:\n\t$0\n\tbreak;";
					snp.documentation = "Defines a range of cases in the current switch-case, with inclusive start and end.\n\nReference: https://dlang.org/spec/statement.html#switch-statement";
					snp.resolved = true;
					snp.unformatted = true;
					res ~= snp;
				}
				{
					Snippet snp;
					snp.providerId = typeid(this).name;
					snp.id = snp.title = snp.shortcut = "default";
					snp.snippet = "case:\n\t$0\n\tbreak;";
					snp.documentation = "Defines the default case in the current switch-case.\n\nReference: https://dlang.org/spec/statement.html#switch-statement";
					snp.resolved = true;
					snp.unformatted = true;
					res ~= snp;
				}
			}
			else
			{
				{
					Snippet snp;
					snp.providerId = typeid(this).name;
					snp.id = snp.title = snp.shortcut = "continue";
					snp.plain = snp.snippet = "continue;";
					snp.documentation = "Continue with next iteration";
					snp.resolved = true;
					snp.unformatted = true;
					res ~= snp;
				}
			}
		}

		return typeof(return).fromResult(res.length ? res : null);
	}

	Future!Snippet resolveSnippet(scope const WorkspaceD.Instance instance,
			scope const(char)[] file, scope const(char)[] code, int position,
			const SnippetInfo info, Snippet snippet)
	{
		return typeof(return).fromResult(snippet);
	}
}
