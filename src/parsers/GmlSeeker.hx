package parsers;
import ace.extern.*;
import electron.FileSystem;
import electron.FileWrap;
import file.FileKind;
import file.kind.*;
import file.kind.gml.*;
import file.kind.gmx.*;
import file.kind.yy.*;
import gml.GmlAPI;
import gmx.*;
import yy.*;
import gml.*;
import haxe.io.Path;
import js.lib.Error;
import js.lib.RegExp;
import parsers.GmlReader;
import tools.CharCode;
import tools.Dictionary;
import tools.Aliases;
import ui.Preferences;
import ui.treeview.TreeView;
import yy.YyObject;
using StringTools;
using tools.NativeString;
using tools.PathTools;

/**
 * Looks for definitions in files/code (for syntax highlighing, auto-completion, etc.)
 * @author YellowAfterlife
 */
class GmlSeeker {
	public static inline var maxAtOnce = 8;
	public static var itemsLeft:Int = 0;
	static var itemQueue:Array<GmlSeekerItem> = [];
	public static function start() {
		itemsLeft = 0;
		itemQueue.resize(0);
	}
	private static function runItem(item:GmlSeekerItem) {
		itemsLeft++;
		FileWrap.readTextFile(item.path, function ready(err:Error, text:String) {
			if (err != null) {
				Main.console.error("Can't index ", item.path, err);
				runNext();
			} else try {
				if (runSync(item.path, text, item.main, item.kind)) {
					runNext();
				}
			} catch (err:Dynamic) {
				Main.console.error("Can't index ", item.path, err);
				runNext();
			}
		});
	}
	public static function run(path:FullPath, main:GmlName, kind:FileKind) {
		var item:GmlSeekerItem = {path:path.ptNoBS(), main:main, kind:kind};
		if (itemsLeft < maxAtOnce) {
			runItem(item);
		} else itemQueue.push(item);
	}
	public static function runFinish():Void {
		GmlAPI.gmlComp.autoSort();
		if (Project.current != null) Project.current.finishedIndexing();
		Main.aceEditor.session.bgTokenizer.start(0);
	}
	public static function runNext():Void {
		var left = --itemsLeft;
		var item = itemQueue.shift();
		if (item != null) {
			runItem(item);
		} else if (left <= 0) {
			runFinish();
		}
	}
	
	private static var jsDoc_full:RegExp = new RegExp("^///\\s*" // start
		//+ "(?:@desc(?:ription)?\\s+)?" // opt: `@desc `
		+ "\\w*[ \t]*(\\(.+)" // `func(...`
	);
	private static var jsDoc_param = new RegExp("^///\\s*"
		+ "@(?:arg|param|argument)\\s+"
		+ "(?:\\{.*?\\}\\s*)?" // {type}?
		+ "(\\S+(?:\\s+=.+)?)" // `arg` or `arg=value`
	);
	private static var gmlDoc_full = new RegExp("^\\s*\\w*\\s*\\(.*\\)");
	private static var parseConst_rx10 = new RegExp("^-?\\d+$");
	private static var parseConst_rx16 = new RegExp("^(?:0x|\\$)([0-9a-fA-F]+)$");
	private static var localType = new RegExp("^/\\*[ \t]*:[ \t]*(\\w+)\\*/$");
	private static function parseConst(s:String):Null<Int> {
		var mt = parseConst_rx10.exec(s);
		if (mt != null) return Std.parseInt(s);
		mt = parseConst_rx16.exec(s);
		if (mt != null) return Std.parseInt("0x" + mt[1]);
		return null;
	}
	
	public static function runSyncImpl(
		orig:FullPath, src:GmlCode, main:String, out:GmlSeekData, locals:GmlLocals, kind:FileKind
	):Void {
		var mainTop = main;
		var sub = null;
		var q = new GmlReaderExt(src);
		var v = GmlAPI.version;
		var row = 0;
		var project = Project.current;
		var notLam = !Std.is(kind, KGmlLambdas);
		var canLam = notLam && project.canLambda();
		var canDefineComp = Std.is(kind, KGml) ? (cast kind:KGml).canDefineComp : false;
		var cubDepth:Int = 0; // depth of {}
		var funcsAreGlobal:Bool = Std.is(kind, KGmlScript) && (cast kind:KGmlScript).isScript;
		var localKind = notLam ? "local" : "sublocal";
		if (project.properties.lambdaMode == Scripts) {
			if (orig.contains("/" + GmlExtLambda.lfPrefix)) {
				canLam = true;
				localKind = "sublocal";
			}
		}
		inline function setLookup(s:String, eol:Bool = false):Void {
			GmlAPI.gmlLookup.set(s, { path: orig, sub: sub, row: row, col: eol ? null : 0 });
			if (s != mainTop) GmlAPI.gmlLookupText += s + "\n";
		}
		if (main != null) setLookup(main);
		/**
		 * A lazy parser.
		 * You tell it what you're looking for, and it reads the input till it finds any of that.
		 */
		function find(flags:GmlSeekerFlags):String {
			while (q.loop) {
				var start = q.pos;
				var c = q.read(), s:String;
				switch (c) {
					case "\r".code: if (flags.has(Line)) return "\n";
					case "\n".code: {
						row += 1;
						if (flags.has(Line)) return "\n";
					};
					case ",".code: if (flags.has(Comma)) return ",";
					case ".".code: if (flags.has(Period)) return ".";
					case ";".code: if (flags.has(Semico)) return ";";
					case "(".code: if (flags.has(Par0)) return "(";
					case ")".code: if (flags.has(Par1)) return ")";
					case "[".code: if (flags.has(Sqb0)) return "[";
					case "]".code: if (flags.has(Sqb1)) return "]";
					case "{".code: cubDepth--; if (flags.has(Cub0)) return "{";
					case "}".code: cubDepth++; if (flags.has(Cub1)) return "}";
					case "=".code: if (flags.has(SetOp) && q.peek() != "=".code) return "=";
					case "/".code: switch (q.peek()) {
						case "/".code: {
							q.skip();
							q.skipLine();
							if (q.get(start + 2) == "!".code && q.get(start + 3) == "#".code) {
								if (q.substring(start + 4, start + 9) == "mfunc") do {
									//  01234567890
									// `//!#mfunc name
									var c = q.get(start + 9);
									if (!c.isSpace0()) break;
									var line = q.substring(start + 10, q.pos);
									var sp = line.indexOf(" ");
									var name = line.substring(0, sp);
									var json = try {
										haxe.Json.parse(line.substring(sp + 1));
									} catch (_:Dynamic) break;
									var mf = new GmlExtMFunc(name, json);
									setLookup(name);
									out.mfuncList.push(mf);
									out.mfuncMap.set(name, mf);
									out.compList.push(mf.comp);
									out.compMap.set(name, mf.comp);
									out.kindList.push(name);
									var tokenType = ace.AceMacro.jsOrx(json.token, "macro.function");
									out.kindMap.set(name, tokenType);
									var mfd = new GmlFuncDoc(name, name + "(", ")", mf.args, false);
									out.docList.push(mfd);
									out.docMap.set(name, mfd);
								} while (false);
							}
							else if (flags.has(Doc) && q.get(start + 2) == "/".code) {
								return q.substring(start, q.pos);
							}
						};
						case "*".code: {
							q.skip();
							row += q.skipComment();
							if (flags.has(ComBlock)) {
								return q.substring(start, q.pos);
							}
						};
						default:
					};
					case '"'.code, "'".code, "`".code, "@".code: row += q.skipStringAuto(c, v);
					case "#".code: {
						q.skipIdent1();
						if (q.pos > start + 1) {
							s = q.substring(start, q.pos);
							switch (s) {
								case "#define","#target": if (flags.has(Define)) {
									if (start == 0) return s;
									c = q.get(start - 1);
									if (c == "\r".code || c == "\n".code) {
										return s;
									}
								};
								case "#macro": if (flags.has(Macro)) return s;
								default:
							}
						}
					};
					default: {
						if (c.isIdent0()) {
							q.skipIdent1();
							var id = q.substring(start, q.pos);
							var m = ace.AceMacro.jsOrx(out.macroMap[id], GmlAPI.gmlMacros[id]);
							if (m != null) {
								if (q.depth < 16) {
									q.pushSource(m.expr);
									return find(flags);
								} else return null;
							}
							if (flags.has(Define) && id == "function") return id;
							if (flags.has(Ident)) return id;
						}
					};
				}
			}
			return null;
		} // find
		var mainComp:AceAutoCompleteItem = main != null ? GmlAPI.gmlAssetComp[main] : null;
		var s:String, name:String, start:Int;
		var doc:GmlFuncDoc = null;
		function flushDoc():Void {
			if (doc == null && main != null) {
				doc = out.docMap[main];
				if (doc == null) {
					doc = new GmlFuncDoc(main, main + "(", ")", [], false);
					out.docList.push(doc);
					out.docMap.set(main, doc);
				}
				doc.fromCode(src, start, q.pos);
				if (mainComp != null) mainComp.doc = doc.getAcText();
			}
			doc = null;
		}
		function procLambdaIdent(s:GmlName, locals:GmlLocals):Void {
			var seekData = GmlExtLambda.seekData;
			var lfLocals = seekData.locals[s];
			if (lfLocals == null && project.properties.lambdaMode == Scripts) {
				//
				var rel = 'scripts/$s/$s.gml';
				var full = project.fullPath(rel);
				var lgml = try {
					project.readTextFileSync(rel);
				} catch (_:Dynamic) null;
				if (lgml == null) {
					Main.console.warn("Lambda missing: " + s);
					lgml = "";
				}
				//
				runSync(full, lgml, "", KGmlLambdas.inst);
				var d = GmlSeekData.map[full];
				if (d == null) {
					Main.console.warn("We just asked to index a lambda script and it's not there..?");
					lfLocals = new GmlLocals();
				} else lfLocals = d.locals[""];
				seekData.locals.set(s, lfLocals);
			}
			if (lfLocals != null) locals.addLocals(lfLocals);
		}
		var p:Int, flags:Int;
		var c:CharCode, mt:RegExpMatch;
		while (q.loop) {
			s = find(Ident | Doc | Define | Macro);
			if (s == null) {
				//
			}
			else if (s.fastCodeAt(0) == "/".code) {
				if (main != null) {
					var check = true, mt;
					if (v.hasLiteralStrings()) {
						mt = jsDoc_param.exec(s);
						if (mt != null) {
							doc = out.docMap[main];
							if (doc == null) {
								doc = GmlFuncDoc.parse(main + "()");
								doc.acc = true;
								out.docList.push(doc);
								out.docMap.set(main, doc);
							}
							if (doc.acc) {
								doc.args.push(mt[1]);
								if (mt[1].contains("...")) doc.rest = true;
								if (mainComp != null) {
									mainComp.doc = doc.getAcText();
								}
							}
							check = false;
						}
					}
					if (check) {
						mt = jsDoc_full.exec(s);
						if (mt != null) {
							if (!out.docMap.exists(main)) {
								doc = GmlFuncDoc.parse(main + mt[1]);
								out.docList.push(doc);
								out.docMap.set(main, doc);
								if (mainComp != null && mainComp.doc == null) {
									mainComp.doc = s;
								}
							}
							check = false;
						} else if (v.hasScriptArgs()) {
							// `#define func(a, b)\n/// does things` -> `func(a, b) does things`
							s = s.substring(3).trimLeft();
							doc = out.docMap[main];
							if (doc == null) {
								if (gmlDoc_full.test(s)) {
									doc = GmlFuncDoc.parse(s);
									doc.name = main;
									doc.pre = main + "(";
								} else doc = GmlFuncDoc.parse(main + "(...) " + s);
								out.docList.push(doc);
								out.docMap.set(main, doc);
							} else {
								if (gmlDoc_full.test(s)) {
									GmlFuncDoc.parse(s, doc);
									doc.name = main;
									doc.pre = main + "(";
								} else doc.post += " " + s;
							}
							mainComp.doc = doc.getAcText();
							check = false;
						}
					}
					if (check) {
						s = s.substring(3).trimBoth();
						if (mainComp != null) mainComp.doc = mainComp.doc.nzcct("\n", s);
					}
				}
			}
			else switch (s) {
				case "#define", "#target", "function": {
					var isDefine = (s == "#define");
					var isFunc = (s == "function");
					if (isFunc && funcsAreGlobal && cubDepth == 0) isDefine = true;
					// we don't have to worry about #event/etc because they
					// do not occur in files themselves
					flushDoc();
					main = find(Ident);
					start = q.pos;
					sub = main;
					row = 0;
					setLookup(main, true);
					locals = new GmlLocals();
					out.locals.set(main, locals);
					if (isFunc || isDefine && v.hasScriptArgs()) { // `#define name(...args)`
						s = find(Line | Par0);
						if (s == "(" && isDefine) {
							var openPos = q.pos;
							flags = Ident | Par1 | (isFunc ? 0 : Line);
							var foundArg = false;
							while (q.loop) {
								s = find(flags);
								if (s == ")" || s == "\n" || s == null) break;
								locals.add(s, localKind);
								foundArg = true;
							}
							if (!isFunc || foundArg) {
								doc = GmlFuncDoc.parse(main + q.substring(start, q.pos));
								out.docList.push(doc);
								out.docMap.set(main, doc);
							}
						}
					}
					//
					if (isDefine && canDefineComp) {
						mainComp = new AceAutoCompleteItem(main, "script",
							q.pos > start ? main + q.substring(start, q.pos) : null);
						out.compList.push(mainComp);
						out.compMap.set(main, mainComp);
						out.kindList.push(main);
						out.kindMap.set(main, "asset.script");
					}
				};
				case "#macro": {
					q.skipSpaces0();
					c = q.peek(); if (!c.isIdent0()) continue;
					p = q.pos;
					q.skipIdent1();
					name = q.substring(p, q.pos);
					// `#macro Config:name`?
					var cfg:String;
					if (q.peek() == ":".code) {
						q.skip();
						c = q.peek();
						if (c.isIdent0()) {
							p = q.pos;
							q.skipIdent1();
							cfg = name;
							name = q.substring(p, q.pos);
						} else cfg = null;
					} else cfg = null;
					q.skipSpaces0();
					// value:
					p = q.pos;
					s = "";
					do {
						q.skipLine();
						if (q.peek( -1) == "\\".code) {
							s += q.substring(p, q.pos - 1) + "\n";
							q.skipLineEnd();
							p = q.pos;
							row += 1;
						} else break;
					} while (q.loopLocal);
					s += q.substring(p, q.pos);
					// we don't currently support configuration nesting
					if (cfg == null || cfg == project.config) {
						var m = new GmlMacro(name, orig, s, cfg);
						var old = out.macroMap[name];
						if (old != null) {
							out.compList.remove(out.compMap[name]);
							out.macroList.remove(old);
						} else {
							out.kindList.push(name);
							if (GmlAPI.stdKind[m.expr] == "keyword") {
								// keyword forwarding
								out.kindMap.set(name, "keyword");
							} else {
								out.kindMap.set(name, "macro");
							}
						}
						//
						var i = name.indexOf("_mf");
						if (i < 0 || !out.mfuncMap.exists(name.substring(0, i))) {
							out.compList.push(m.comp);
							out.compMap.set(name, m.comp);
							setLookup(name, true);
						} else {
							// adjust for mfunc rows being hidden
							row -= 1;
						}
						//
						out.macroList.push(m);
						out.macroMap.set(name, m);
					}
				};
				case "globalvar": {
					while (q.loop) {
						s = find(Ident | Semico);
						if (s == null || s == ";" || GmlAPI.kwFlow.exists(s)) break;
						var g = new GmlGlobalVar(s, orig);
						out.globalVarList.push(g);
						out.globalVarMap.set(s, g);
						out.compList.push(g.comp);
						out.compMap.set(s, g.comp);
						out.kindList.push(s);
						out.kindMap.set(s, "globalvar");
						setLookup(s);
					}
				};
				case "global": {
					if (find(Period | Ident) == ".") {
						s = find(Ident);
						if (s != null && out.globalFieldMap[s] == null) {
							var gfd = GmlAPI.gmlGlobalFieldMap[s];
							if (gfd == null) {
								gfd = new GmlGlobalField(s);
								GmlAPI.gmlGlobalFieldMap.set(s, gfd);
							}
							out.globalFieldList.push(gfd);
							out.globalFieldMap.set(s, gfd);
							out.globalFieldComp.push(gfd.comp);
						}
					}
				};
				case "var": {
					while (q.loop) {
						name = find(Ident);
						if (name == null) break;
						if (name == "var") { // `var var`
							name = find(Ident);
						} else if (GmlAPI.kwFlow[name]) {
							// might eat a structure but that code's broken anyway
							break;
						}
						locals.add(name, localKind);
						p = q.pos;
						flags = SetOp | Comma | Semico | Ident | ComBlock;
						s = find(flags);
						if (s != null && s.startsWith("/*")) { // name/*...*/
							mt = localType.exec(s);
							if (mt != null) {
								locals.type.set(name, mt[1]);
							}
							s = find(flags);
						}
						if (s == ",") {
							// OK, next
						} else if (s == "=") {
							// name = (balanced expression)[,;]
							var depth = 0;
							var exit = false;
							while (q.loop) {
								p = q.pos;
								s = find(Par0 | Par1 | Sqb0 | Sqb1 | Cub0 | Cub1
									| Comma | Semico | Ident);
								// EOF:
								if (s == null) {
									exit = true;
									break;
								}
								switch (s) {
									case "(", "[", "{": depth += 1;
									case ")", "]", "}": depth -= 1;
									case ",": if (depth == 0) break;
									case ";": exit = true; break;
									default: { // ident
										if (GmlAPI.kwFlow[s]) {
											q.pos = p;
											exit = true;
											break;
										} else if (canLam && s.startsWith(GmlExtLambda.lfPrefix)) {
											procLambdaIdent(s, locals);
											continue;
										}
									};
								}
							}
							if (exit) break;
						} else {
							// EOF or `var name something_else`
							q.pos = p;
							break;
						}
					}
				};
				case "enum": {
					name = find(Ident);
					if (name == null) continue;
					if (find(Cub0) == null) continue;
					var en = new GmlEnum(name, orig);
					out.enumList.push(en);
					out.enumMap.set(name, en);
					out.compList.push(new AceAutoCompleteItem(name, "enum"));
					setLookup(name);
					var nextVal:Null<Int> = 0;
					while (q.loop) {
						s = find(Ident | Cub1);
						if (s == null || s == "}") break;
						en.lastItem = s;
						en.names.push(s);
						en.items.set(s, true);
						var ac = new AceAutoCompleteItem(name + "." + s, "enum");
						var acf = new AceAutoCompleteItem(s, "enum");
						en.compList.push(ac);
						en.fieldComp.push(acf);
						en.compMap.set(s, ac);
						en.fieldLookup.set(s, { path: orig, sub: sub, row: row, col: 0, });
						s = find(Comma | SetOp | Cub1);
						if (s == "=") {
							//
							var doc = null;
							var vp = q.pos;
							while (vp < q.length) {
								var c = q.get(vp++);
								switch (c) {
									case "\r".code, "\n".code: break;
									case "/".code if (q.get(vp) == "/".code): {
										var docStart = ++vp;
										while (vp < q.length) {
											c = q.get(vp);
											if (c == "\r".code || c == "\n".code) break;
											vp++;
										}
										doc = q.substring(docStart, vp).trimBoth();
									};
								}
							}
							//
							vp = q.pos;
							s = find(Comma | Cub1);
							var val = parseConst(q.substring(vp, q.pos - 1).trimBoth());
							if (val != null) {
								acf.doc = ac.doc = "" + val;
								nextVal = val + 1;
							} else nextVal = null;
							if (doc != null) {
								acf.doc = acf.doc != null ? acf.doc + "\t" + doc : doc;
								ac.doc = acf.doc;
							}
						} else if (nextVal != null) {
							acf.doc = ac.doc = "" + (nextVal++);
						}
						if (s == null || s == "}") break;
					}
				};
				default: { // maybe an instance field assignment
					// skip if it's a local/built-in/project/extension identifier:
					if (locals.kind[s] != null) continue;
					if (canLam && s.startsWith(GmlExtLambda.lfPrefix)) {
						procLambdaIdent(s, locals);
						continue;
					}
					if (GmlAPI.gmlKind[s] != null) continue;
					if (GmlAPI.extKind[s] != null) continue;
					if (GmlAPI.stdKind[s] != null) continue;
					var skip = false, i;
					// skip if it's `field.some`
					i = q.pos - s.length;
					while (--i >= 0) switch (q.get(i)) {
						case " ".code, "\t".code, "\r".code, "\n".code: { };
						case ".".code: skip = true; break;
						default: break;
					}
					if (skip) continue;
					// skip unless it's `some =` (and no `some ==`)
					i = q.pos;
					while (i < q.length) switch (q.get(i++)) {
						case " ".code, "\t".code, "\r".code, "\n".code: { };
						case "=".code: skip = q.get(i) == "=".code; break;
						default: skip = true; break;
					}
					if (skip) continue;
					// that's an instance variable then
					if (out.instFieldMap[s] == null) {
						var fd = GmlAPI.gmlInstFieldMap[s];
						if (fd == null) {
							fd = new GmlField(s, "variable");
							GmlAPI.gmlInstFieldMap.set(s, fd);
						}
						out.instFieldList.push(fd);
						out.instFieldMap.set(s, fd);
						out.instFieldComp.push(fd.comp);
					}
				};
			} // switch (s)
		} // while
		flushDoc();
		//
		if (project.hasGMLive) out.hasGMLive = out.hasGMLive || ui.GMLive.check(src);
	}
	
	public static function finish(orig:String, out:GmlSeekData):Void {
		GmlSeekData.apply(orig, GmlSeekData.map[orig], out);
		GmlSeekData.map.set(orig, out);
		out.compList.autoSort();
	}
	public static function addObjectChild(parentName:String, childName:String) {
		var pj = Project.current;
		var parChildren = pj.objectChildren[parentName];
		if (parChildren == null) {
			parChildren = [];
			pj.objectChildren.set(parentName, parChildren);
		}
		parChildren.push(childName);
	}
	public static function runSync(path:String, content:String, main:String, kind:FileKind) {
		return kind.index(path, content, main);
	} // runSync
}

typedef GmlSeekerItem = {
	path:String,
	main:String,
	kind:FileKind,
}

@:build(tools.AutoEnum.build("bit"))
@:enum abstract GmlSeekerFlags(Int) from Int to Int {
	var Ident;
	var Define;
	/** `#macro` */
	var Macro;
	/** `/// ...` */
	var Doc;
	/** `/* ...` */
	var ComBlock;
	var Cub0;
	var Cub1;
	var Comma;
	var Period;
	var Semico;
	var SetOp;
	var Line;
	var Par0;
	var Par1;
	var Sqb0;
	var Sqb1;
	//
	public inline function has(flag:GmlSeekerFlags) {
		return this & flag != 0;
	}
}
