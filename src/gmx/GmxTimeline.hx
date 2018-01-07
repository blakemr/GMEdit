package gmx;
import gml.GmlTimeline;

/**
 * ...
 * @author YellowAfterlife
 */
class GmxTimeline {
	public static var errorText:String;
	public static function getCode(tl:SfGmx):String {
		var out = "";
		var errors = "";
		for (entry in tl.findAll("entry")) {
			if (out != "") out += "\n";
			var name = entry.findText("step");
			out += "#moment " + name;
			var event = entry.find("event");
			var code = GmxEvent.getCode(event);
			if (code != null) {
				code = ~/^\/\/\/\s*(.*)\r?\n/g.map(code, function(rx:EReg) {
					out += " " + rx.matched(1);
					return "";
				});
				if (event.find("action") != null) out += "\n";
				out += code;
			} else {
				errors += "Unreadable action in moment " + name + "\n";
				errors += "Only self-applied code blocks are supported.\n";
			}
		}
		if (errors != "") {
			errorText = errors;
			return null;
		} else return out;
	}
	public static function setCode(tl:SfGmx, gmlCode:String):Bool {
		var data = GmlTimeline.parse(gmlCode, gml.GmlVersion.v1);
		if (data == null) {
			errorText = GmlTimeline.parseError;
			return false;
		}
		tl.clearChildren();
		data.sort(function(a, b) return a.moment - b.moment);
		for (item in data) {
			var entry = new SfGmx("entry"); tl.addChild(entry);
			entry.addTextChild("step", "" + item.moment);
			var event = new SfGmx("event"); entry.addChild(event);
			for (code in item.code) event.addChild(GmxAction.makeCodeBlock(code + "\r\n"));
		}
		return true;
	}
}