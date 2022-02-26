function d
	dub run :dml
	if dub build $argv
		dub run :test
	end
end

function b
	dub run :dml
	dub build $argv
	mv workspace-d ~/etc-bin/workspace-d
	killall dcd-server; killall workspace-d
end

function r
	dub run :dml
	dub build --build=release $argv
end
