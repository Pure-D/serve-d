module served.linters.diagnosticmanager;

import served.types;

import painlessjson;

enum NumDiagnosticProviders = 2;
alias DiagnosticCollection = PublishDiagnosticsParams[];
DiagnosticCollection[NumDiagnosticProviders] diagnostics;

DiagnosticCollection combinedDiagnostics;

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
			RequestMessage request;
			request.method = "textDocument/publishDiagnostics";
			request.params = diagnostics.toJSON;
			rpc.send(request);
		}
	}
}
