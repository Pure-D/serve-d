module served.linters.diagnosticmanager;

import std.array : array;
import std.algorithm : map, sort;

import served.io.memory;
import served.types;

import painlessjson;

enum NumDiagnosticProviders = 2;
alias DiagnosticCollection = PublishDiagnosticsParams[];
DiagnosticCollection[NumDiagnosticProviders] diagnostics;

DiagnosticCollection combinedDiagnostics;
DocumentUri[] publishedUris;

void combineDiagnostics()
{
	combinedDiagnostics.length = 0;
	foreach (provider; diagnostics)
	{
		foreach (errors; provider)
		{
			size_t index = combinedDiagnostics.length;
			foreach (i, existing; combinedDiagnostics)
			{
				if (existing.uri == errors.uri)
				{
					index = i;
					break;
				}
			}
			if (index == combinedDiagnostics.length)
				combinedDiagnostics ~= PublishDiagnosticsParams(errors.uri);
			combinedDiagnostics[index].diagnostics ~= errors.diagnostics;
		}
	}
}

void updateDiagnostics(string uriHint = "")
{
	combineDiagnostics();
	foreach (diagnostics; combinedDiagnostics)
	{
		if (!uriHint.length || diagnostics.uri == uriHint)
		{
			// TODO: related information
			RequestMessage request;
			request.method = "textDocument/publishDiagnostics";
			request.params = diagnostics.toJSON;
			rpc.send(request);
		}
	}

	// clear old diagnostics
	auto diags = combinedDiagnostics.map!"a.uri".array;
	auto sorted = diags.sort!"a<b";
	foreach (submitted; publishedUris)
	{
		if (!sorted.contains(submitted))
		{
			RequestMessage request;
			request.method = "textDocument/publishDiagnostics";
			request.params = PublishDiagnosticsParams(submitted, null).toJSON;
			rpc.send(request);
		}
	}
	destroyUnset(publishedUris);
	publishedUris = diags;
}
