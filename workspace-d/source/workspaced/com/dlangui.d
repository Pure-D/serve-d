module workspaced.com.dlangui;

import core.thread;
import std.algorithm;
import std.json;
import std.process;
import std.string;
import std.uni;

import workspaced.api;
import workspaced.completion.dml;

@component("dlangui")
@globalOnly
class DlanguiComponent : ComponentWrapper
{
	mixin DefaultGlobalComponentWrapper;

	/// Queries for code completion at position `pos` in DML code
	/// Returns: `[{type: CompletionType, value: string, documentation: string, enumName: string}]`
	/// Where type is an integer
	Future!(CompletionItem[]) complete(scope const(char)[] code, int pos)
	{
		auto ret = new typeof(return);
		gthreads.create({
			mixin(traceTask);
			try
			{
				LocationInfo info = getLocationInfo(code, pos);
				CompletionItem[] suggestions;
				string name = info.itemScope[$ - 1];
				string[] stack;
				if (info.itemScope.length > 1)
					stack = info.itemScope[0 .. $ - 1];
				string[][] curScope = stack.getProvidedScope();
				if (info.type == LocationType.RootMember)
				{
					foreach (CompletionLookup item; dmlCompletions)
					{
						if (item.item.type == CompletionType.Class)
						{
							if (name.length == 0 || item.item.value.canFind(name))
							{
								suggestions ~= item.item;
							}
						}
					}
				}
				else if (info.type == LocationType.Member)
				{
					foreach (CompletionLookup item; dmlCompletions)
					{
						if (item.item.type == CompletionType.Class)
						{
							if (name.length == 0 || item.item.value.canFind(name))
							{
								suggestions ~= item.item;
							}
						}
						else if (item.item.type != CompletionType.EnumDefinition)
						{
							if (curScope.canFind(item.requiredScope))
							{
								if (name.length == 0 || item.item.value.canFind(name))
								{
									suggestions ~= item.item;
								}
							}
						}
					}
				}
				else if (info.type == LocationType.PropertyValue)
				{
					foreach (CompletionLookup item; dmlCompletions)
					{
						if (item.item.type == CompletionType.EnumValue)
						{
							if (curScope.canFind(item.requiredScope))
							{
								if (item.item.value == name)
								{
									foreach (CompletionLookup enumdef; dmlCompletions)
									{
										if (enumdef.item.type == CompletionType.EnumDefinition)
										{
											if (enumdef.item.enumName == item.item.enumName)
												suggestions ~= enumdef.item;
										}
									}
									break;
								}
							}
						}
						else if (item.item.type == CompletionType.Boolean)
						{
							if (curScope.canFind(item.requiredScope))
							{
								if (item.item.value == name)
								{
									suggestions ~= CompletionItem(CompletionType.Keyword, "true");
									suggestions ~= CompletionItem(CompletionType.Keyword, "false");
									break;
								}
							}
						}
					}
				}
				ret.finish(suggestions);
			}
			catch (Throwable e)
			{
				ret.error(e);
			}
		});
		return ret;
	}
}

///
enum CompletionType : ubyte
{
	///
	Undefined = 0,
	///
	Class = 1,
	///
	String = 2,
	///
	Number = 3,
	///
	Color = 4,
	///
	EnumDefinition = 5,
	///
	EnumValue = 6,
	///
	Rectangle = 7,
	///
	Boolean = 8,
	///
	Keyword = 9,
}

/// Returned by list-completion
struct CompletionItem
{
	///
	CompletionType type;
	///
	string value;
	///
	string documentation = "";
	///
	string enumName = "";
}

struct CompletionLookup
{
	CompletionItem item;
	string[][] providedScope = [];
	string[] requiredScope = [];
}

private:

string[][] getProvidedScope(string[] stack)
{
	if (stack.length == 0)
		return [];
	string[][] providedScope;
	foreach (CompletionLookup item; dmlCompletions)
	{
		if (item.item.type == CompletionType.Class)
		{
			if (item.item.value == stack[$ - 1])
			{
				providedScope ~= item.providedScope;
				break;
			}
		}
	}
	return providedScope;
}

enum LocationType : ubyte
{
	RootMember,
	Member,
	PropertyValue,
	None
}

struct LocationInfo
{
	LocationType type;
	string[] itemScope;
	string propertyName;
}

LocationInfo getLocationInfo(scope const(char)[] code, int pos)
{
	LocationInfo current;
	current.type = LocationType.RootMember;
	current.itemScope = [];
	current.propertyName = "";
	string member = "";
	bool inString = false;
	bool escapeChar = false;
	foreach (i, c; code)
	{
		if (i == pos)
			break;
		if (inString)
		{
			if (escapeChar)
				escapeChar = false;
			else
			{
				if (c == '\\')
				{
					escapeChar = true;
				}
				else if (c == '"')
				{
					inString = false;
					current.type = LocationType.None;
					member = "";
					escapeChar = false;
				}
			}
			continue;
		}
		else
		{
			if (c == '{')
			{
				current.itemScope ~= member;
				current.propertyName = "";
				member = "";
				current.type = LocationType.Member;
			}
			else if (c == '\n' || c == '\r' || c == ';')
			{
				current.propertyName = "";
				member = "";
				current.type = LocationType.Member;
			}
			else if (c == ':')
			{
				current.propertyName = member;
				member = "";
				current.type = LocationType.PropertyValue;
			}
			else if (c == '"')
			{
				inString = true;
			}
			else if (c == '}')
			{
				if (current.itemScope.length > 0)
					current.itemScope.length--;
				current.type = LocationType.None;
				current.propertyName = "";
				member = "";
			}
			else if (c.isWhite)
			{
				if (current.type == LocationType.None)
					current.type = LocationType.Member;
				if (current.itemScope.length == 0)
					current.type = LocationType.RootMember;
			}
			else
			{
				if (current.type == LocationType.Member || current.type == LocationType.RootMember)
					member ~= c;
			}
		}
	}
	if (member.length)
		current.propertyName = member;
	current.itemScope ~= current.propertyName;
	return current;
}

unittest
{
	auto info = getLocationInfo(" ", 0);
	assert(info.type == LocationType.RootMember);
	info = getLocationInfo(`TableLayout { mar }`, 17);
	assert(info.itemScope == ["TableLayout", "mar"]);
	assert(info.type == LocationType.Member);
	info = getLocationInfo(`TableLayout { margins: 20; paddin }`, 33);
	assert(info.itemScope == ["TableLayout", "paddin"]);
	assert(info.type == LocationType.Member);
	info = getLocationInfo(
			"TableLayout { margins: 20; padding : 10\n\t\tTextWidget { text: \"} foo } }", 70);
	assert(info.itemScope == ["TableLayout", "TextWidget", "text"]);
	assert(info.type == LocationType.PropertyValue);
	info = getLocationInfo(`TableLayout { margins: 2 }`, 24);
	assert(info.itemScope == ["TableLayout", "margins"]);
	assert(info.type == LocationType.PropertyValue);
	info = getLocationInfo(
			"TableLayout { margins: 20; padding : 10\n\t\tTextWidget { text: \"} foobar\" } } ", int.max);
	assert(info.itemScope == [""]);
	assert(info.type == LocationType.RootMember);
	info = getLocationInfo(
			"TableLayout { margins: 20; padding : 10\n\t\tTextWidget { text: \"} foobar\"; } }", 69);
	assert(info.itemScope == ["TableLayout", "TextWidget", "text"]);
	assert(info.type == LocationType.PropertyValue);
	info = getLocationInfo("TableLayout {\n\t", int.max);
	assert(info.itemScope == ["TableLayout", ""]);
	assert(info.type == LocationType.Member);
	info = getLocationInfo(`TableLayout {
	colCount: 2
	margins: 20; padding: 10
	backgroundColor: "#FFFFE0"
	TextWidget {
		t`, int.max);
	assert(info.itemScope == ["TableLayout", "TextWidget", "t"]);
	assert(info.type == LocationType.Member);
}
