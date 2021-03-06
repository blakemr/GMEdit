package parsers.linter;
import gml.GmlFuncDoc;
import tools.Aliases;
import tools.Dictionary;
import editors.EditCode;
import parsers.linter.GmlLinterKind;
import gml.GmlVersion;
import ace.extern.*;
import tools.macros.GmlLinterMacros.*;
import gml.GmlAPI;
using tools.NativeArray;
using tools.NativeString;

/**
 * ...
 * @author YellowAfterlife
 */
class GmlLinter {
	
	public static function getOption(fn:GmlLinterPrefs->Bool):Bool {
		var lp = gml.Project.current.properties.linterPrefs;
		var r:Bool = null;
		for (_ in 0 ... 1) {
			if (lp != null) {
				r = fn(lp);
				if (r != null) break;
			}
			r = fn(ui.Preferences.current.linterPrefs);
			if (r != null) break;
			r = fn(GmlLinterPrefs.defValue);
		}
		return r;
	}
	//
	public var errorText:String = null;
	public var errorPos:AcePos = null;
	function setError(text:String):Void {
		if (errorPos != null) return;
		errorText = text + reader.getStack();
		errorPos = reader.getTopPos();
	}
	//
	public var warnings:Array<GmlLinterProblem> = [];
	function addWarning(text:String):Void {
		warnings.push(new GmlLinterProblem(text + reader.getStack(), reader.getTopPos()));
	}
	public var errors:Array<GmlLinterProblem> = [];
	function addError(text:String):Void {
		errors.push(new GmlLinterProblem(text + reader.getStack(), reader.getTopPos()));
	}
	//
	
	/** top-level context name */
	var name:String;
	
	var reader:GmlReaderExt;
	
	var editor:EditCode;
	
	var context:String = "";
	
	/** depth -> null<variables that should be freed after this depth> */
	var localNamesPerDepth:Array<Array<String>> = [];
	var localKinds:Dictionary<GmlLinterKind> = new Dictionary();
	
	
	var isProperties:Bool = false;
	
	/** Used for storing stacktrace when reading {...}/[...]/etc. */
	var seqStart:GmlReaderExt = new GmlReaderExt("", GmlVersion.none);
	function readSeqStartError(text:String):FoundError {
		if (errorPos != null) return true;
		errorText = text + seqStart.getStack();
		errorPos = seqStart.getTopPos();
		return true;
	}
	function readSeqStartWarn(text:String):FoundError {
		if (errorPos != null) return true;
		warnings.push(new GmlLinterProblem(text + seqStart.getStack(), seqStart.getTopPos()));
		return true;
	}
	
	var version:GmlVersion;
	
	var optRequireSemico:Bool;
	var optNoSingleEqu:Bool;
	var optRequireParentheses:Bool;
	var optBlockScopedVar:Bool;
	var optRequireFunctions:Bool;
	var optBlockScopedCase:Bool;
	
	public function new() {
		optRequireSemico = getOption((q) -> q.requireSemicolons);
		optNoSingleEqu = getOption((q) -> q.noSingleEquals);
		optRequireParentheses = getOption((q) -> q.requireParentheses);
		optBlockScopedVar = getOption((q) -> q.blockScopedVar);
		optBlockScopedCase = getOption((q) -> q.blockScopedCase);
		optRequireFunctions = getOption((q) -> q.requireFunctions);
	}
	//{
	var nextKind:GmlLinterKind = KEOF;
	var nextVal(get, set):String;
	function get_nextVal():String {
		if (__nextVal_cache == null) {
			__nextVal_cache = __nextVal_source.substring(__nextVal_start, __nextVal_end);
		}
		return __nextVal_cache;
	}
	inline function set_nextVal(s:String):String {
		return __nextVal_cache = s;
	}
	var __nextVal_cache:String = null;
	var __nextVal_source:String = "";
	var __nextVal_start:Int = 0;
	var __nextVal_end:Int = 0;
	function nextDump():String {
		var v = nextVal;
		if (v != "") {
			return '`$v` (${nextKind.getName()})';
		} else return nextKind.getName();
	}
	//
	function __next_ret(nvk:GmlLinterKind, src:String, nv0:Int, nv1:Int):GmlLinterKind {
		//if (!__next_isPeek) Main.console.log(reader.getTopPosString(), nvk, nvk.getName(), src.substring(nv0, nv1));
		__nextVal_cache = null;
		__nextVal_source = src;
		__nextVal_start = nv0;
		__nextVal_end = nv1;
		nextKind = nvk;
		return nvk;
	}
	function __next_retv(nvk:GmlLinterKind, nv:String):GmlLinterKind {
		//if (!__next_isPeek) Main.console.log(reader.getTopPosString(), nvk, nvk.getName(), nv);
		__nextVal_cache = nv;
		nextKind = nvk;
		return nvk;
	}
	//
	var keywords:Dictionary<GmlLinterKind>;
	function initKeywords() {
		var q = new Dictionary<GmlLinterKind>();
		q["var"] = KVar;
		q["globalvar"] = KGlobalVar;
		q["enum"] = KEnum;
		//
		q["undefined"] = KUndefined;
		//
		q["not"] = KNot;
		q["and"] = KBoolAnd;
		q["or"] = KBoolOr;
		q["xor"] = KBoolXor;
		//
		q["div"] = KIntDiv;
		q["mod"] = KMod;
		//
		//
		q["begin"] = KCubOpen;
		q["end"] = KCubClose;
		q["if"] = KIf;
		q["then"] = KThen;
		q["else"] = KElse;
		q["return"] = KReturn;
		q["exit"] = KExit;
		//
		q["for"] = KFor;
		q["while"] = KWhile;
		q["do"] = KDo;
		q["until"] = KUntil;
		q["repeat"] = KRepeat;
		q["with"] = KWith;
		q["break"] = KBreak;
		q["continue"] = KContinue;
		//
		q["switch"] = KSwitch;
		q["case"] = KCase;
		q["default"] = KDefault;
		//
		q["try"] = KTry;
		q["catch"] = KCatch;
		q["finally"] = KFinally;
		q["throw"] = KThrow;
		//
		var kws = version.config.additionalKeywords;
		if (kws != null) {
			inline function addOpt(name:String, k:GmlLinterKind) {
				if (kws.indexOf(name) >= 0) q[name] = k;
			}
			addOpt("in", KLiveIn);
			addOpt("wait", KLiveWait);
			addOpt("new", KNew);
			addOpt("delete", KDelete);
			addOpt("function", KFunction);
			addOpt("static", KStatic);
			addOpt("constructor", KConstructor);
		}
		//
		keywords = q;
	}
	
	//
	var __next_isPeek = false;
	function __next(q:GmlReaderExt):GmlLinterKind {
		var nk:GmlLinterKind;
		var nv:String;
		//
		var _src:String;
		inline function start():Void {
			_src = q.source;
		}
		//
		while (q.loop) {
			var p = q.pos;
			var c = q.read();
			inline function ret(nk:GmlLinterKind):GmlLinterKind {
				return __next_ret(nk, _src, p, q.pos);
			}
			inline function retv(nk:GmlLinterKind, nv:String):GmlLinterKind {
				return __next_retv(nk, nv);
			}
			switch (c) {
				case "\n".code: q.markLine();
				case "/".code: switch (q.peek()) {
					case "/".code: q.skipLine();
					case "*".code: q.skip(); q.skipComment();
					default: {
						if (q.peek() == "=".code) {
							q.skip();
							return retv(KSetOp, "/=");
						} else return retv(KDiv, "/");
					};
				};
				case '"'.code, "'".code, "`".code: {
					start();
					q.skipStringAuto(c, version);
					return ret(KString);
				};
				//
				case "?".code: return retv(KQMark, "?");
				case ":".code: {
					if (q.peek() == "=".code) {
						q.skip();
						return retv(KSet, ":=");
					} else return retv(KColon, ":");
				};
				case "@".code: {
					if (version.hasLiteralStrings()) {
						c = q.peek();
						if (c == '"'.code || c == "'".code) {
							start();
							q.skip();
							q.skipString1(c);
							return ret(KString);
						}
					}
					return retv(KAtSign, "@");
				};
				case "#".code: {
					c = q.peek();
					if (c.isIdent0()) {
						p++;
						q.skipIdent1();
						nv = q.substring(p, q.pos);
						switch (nv) {
							case "mfunc", "macro": {
								start();
								while (q.loopLocal) {
									q.skipLine();
									if (q.peek( -1) != "\\".code) break;
									q.skipLineEnd();
									q.markLine();
								}
								return ret(nv == "macro" ? KMacro : KMFuncDecl);
							};
							case "args": {
								q.skipLine();
								return retv(KArgs, "#args");
							};
							case "lambda": return retv(KLambda, "#lambda");
							case "lamdef": return retv(KLamDef, "#lamdef");
							case "import", "hyper": {
								q.skipLine();
							};
							case "define", "event", "moment", "target": {
								if (p - 2 <= 0 || q.get(p - 2) == "\n".code) {
									//q.row = 0;
									//q.pos = p;
									q.pos = p;
									context = q.readContextName(null);
									localNamesPerDepth = [];
									localKinds = new Dictionary();
									isProperties = nv == "event" && context == "properties";
									q.skipLine();
								} else {
									q.pos = p; return retv(KHash, "#");
								}
							};
							case "gmcr": {
								if (keywords["yield"] == null) {
									keywords["yield"] = KYield;
									keywords["label"] = KLabel;
									keywords["goto"] = KGoto;
								}
							};
							case "region", "endregion", "section": {
								q.skipLine();
							};
							default: q.pos = p; return retv(KHash, "#");
						}
					} else return retv(KHash, "#");
				};
				case "$".code: {
					start();
					q.skipHex();
					return ret(KNumber);
				};
				case ";".code: return retv(KSemico, ";");
				case ",".code: return retv(KComma, ",");
				//
				case "(".code: return retv(KParOpen, "(");
				case ")".code: return retv(KParClose, ")");
				case "[".code: return retv(KSqbOpen, "[");
				case "]".code: return retv(KSqbClose, "]");
				case "{".code: return retv(KCubOpen, "{");
				case "}".code: return retv(KCubClose, "}");
				//
				case "=".code: {
					if (q.peek() == "=".code) {
						q.skip();
						return retv(KEQ, "==");
					} else return retv(KSet, "=");
				};
				case "!".code: {
					if (q.peek() == "=".code) {
						q.skip();
						return retv(KNE, "!=");
					} else return retv(KNot, "!");
				};
				//
				case "+".code: {
					switch (q.peek()) {
						case "=".code: q.skip(); return retv(KSetOp, "+=");
						case "+".code: q.skip(); return retv(KInc, "++");
						default: return retv(KAdd, "+");
					}
				};
				case "-".code: {
					switch (q.peek()) {
						case "=".code: q.skip(); return retv(KSetOp, "-=");
						case "-".code: q.skip(); return retv(KDec, "--");
						default: return retv(KSub, "-");
					}
				};
				//
				case "*".code: {
					if (q.peek() == "=".code) {
						q.skip();
						return retv(KSetOp, "*=");
					} else return retv(KMul, "*");
				};
				case "%".code: {
					if (q.peek() == "=".code) {
						q.skip();
						return retv(KSetOp, "%=");
					} else return retv(KMod, "%");
				};
				//
				case "|".code: {
					switch (q.peek()) {
						case "=".code: q.skip(); return retv(KSetOp, "|=");
						case "|".code: q.skip(); return retv(KBoolOr, "||");
						default: return retv(KOr, "|");
					}
				};
				case "&".code: {
					switch (q.peek()) {
						case "=".code: q.skip(); return retv(KSetOp, "&=");
						case "&".code: q.skip(); return retv(KBoolAnd, "&&");
						default: return retv(KAnd, "&");
					}
				};
				case "^".code: {
					switch (q.peek()) {
						case "=".code: q.skip(); return retv(KSetOp, "^=");
						case "&".code: q.skip(); return retv(KBoolXor, "^^");
						default: return retv(KXor, "^");
					}
				};
				case "~".code: return retv(KBitNot, "~");
				//
				case ">".code: {
					switch (q.peek()) {
						case "=".code: q.skip(); return retv(KGE, ">=");
						case ">".code: q.skip(); return retv(KShr, ">>");
						default: return retv(KGT, ">");
					}
				};
				case "<".code: {
					switch (q.peek()) {
						case "=".code: q.skip(); return retv(KLE, "<=");
						case "<".code: q.skip(); return retv(KShl, "<<");
						case ">".code: q.skip(); return retv(KNE, "<>");
						default: return retv(KLT, "<");
					}
				};
				//
				case ".".code: {
					c = q.peek();
					if (c.isDigit()) {
						start();
						q.skipNumber(false);
						return ret(KNumber);
					} else return retv(KDot, ".");
				};
				default: {
					if (c.isIdent0()) {
						q.skipIdent1();
						nv = q.substring(p, q.pos);
						do {
							//
							if (nv != "var") {
								var imp = editor.imports[context];
								if (imp != null) {
									var ir = GmlLinterImports.proc(this, q, p, imp, nv);
									if (ir) return KEOF;
									if (ir != null) return __next(q);
								}
							}
							//
							var mf = GmlAPI.gmlMFuncs[nv];
							if (mf != null) {
								if (GmlLinterMFunc.read(this, q, nv)) return KEOF;
								break;
							}
							// expand macros:
							var mcr = GmlAPI.gmlMacros[nv];
							if (mcr != null) {
								if (q.depth > 128) {
									setError("Macro stack overflow");
									return KEOF;
								}
								if (mcr.expr == "var") switch (mcr.name) {
									case "const": return retv(KConst, nv);
									case "let": return retv(KLet, nv);
								}
								q.pushSource(mcr.expr, mcr.name);
								break;
							}
							return retv(keywords.defget(nv, KIdent), nv);
						} while (false);
					}
					else if (c.isDigit()) {
						start();
						if (q.peek() == "x".code) {
							q.skip();
							q.skipHex();
						} else {
							q.skipNumber();
						}
						return ret(KNumber);
					}
					else if (c.code > 32) {
						setError("Can't parse `" + String.fromCharCode(c) + "`");
						return KEOF;
					}
				};
			}
		}
		start();
		return __next_retv(KEOF, "");
	}
	//
	inline function next():GmlLinterKind {
		return __next(reader);
	}
	//
	private var __peekReader:GmlReaderExt = new GmlReaderExt("", GmlVersion.none);
	function peek() {
		var q = __peekReader;
		q.setTo(reader);
		var wasPeek = __next_isPeek;
		__next_isPeek = true;
		var r = __next(q);
		__next_isPeek = wasPeek;
		__skipAvail = true;
		return r;
	}
	var __skipAvail = false;
	function skip() {
		if (__skipAvail) {
			__skipAvail = false;
			reader.setTo(__peekReader);
			return nextKind;
		} else throw "Can't skip - didn't peek";
	}
	function skipIf(cond:Bool) {
		if (cond) {
			reader.setTo(__peekReader);
		}
		__skipAvail = false;
		return cond;
	}
	//
	inline function nextOr(nk:GmlLinterKind):GmlLinterKind {
		return nk != null ? nk : next();
	}
	//}
	function readError(s:String):FoundError {
		setError(s);
		return true;
	}
	function readExpect(s:String):FoundError {
		setError('Expected $s, got ' + nextDump());
		return true;
	}
	
	/** if (next() != kind) error */
	function readCheckSkip(kind:GmlLinterKind, expect:String):FoundError {
		if (next() == kind) return false;
		return readExpect(expect);
	}
	//
	function __readExpr_invalid(flags:GmlLinterReadFlags):FoundError {
		return readExpect(flags.has(AsStat) ? "a statement" : "an expression");
	}
	
	/** `+¦ a - b;` -> `+ a - b¦;` */
	function readOps(oldDepth:Int):FoundError {
		var newDepth = oldDepth + 1;
		var q = reader;
		while (q.loop) {
			rc(readExpr(newDepth, NoOps));
			var nk = peek();
			if (nk.isBinOp() || nk == KSet) {
				skip();
			} else break;
		}
		return false;
	}
	
	/**
	 * 
	 * @param	sqb Whether this is a [...args]
	 * @return	number of arguments read, -1 on error
	 */
	function readArgs(oldDepth:Int, sqb:Bool):Int {
		var newDepth = oldDepth + 1;
		var q = reader;
		seqStart.setTo(reader);
		var seenComma = true;
		var closed = false;
		var argc = 0;
		while (q.loop) {
			switch (peek()) {
				case KParClose: {
					if (sqb) { readError("Unexpected `)`"); return -1; }
					skip(); closed = true; break;
				};
				case KSqbClose: {
					if (!sqb) { readError("Unexpected `]`"); return -1; }
					skip(); closed = true; break;
				};
				case KComma: {
					if (seenComma) {
						readError("Unexpected `,`");
						return -1;
					} else {
						seenComma = true;
						skip();
					}
				};
				default: {
					if (seenComma) {
						seenComma = false;
						if (readExpr(newDepth)) return -1;
						argc++;
					} else {
						readExpect("a comma in values list");
						return -1;
					}
				};
			}
		}
		if (!closed) {
			readSeqStartError("Unclosed " + (sqb ? "[]" : "()"));
			return -1;
		} else return argc;
	}
	
	function checkCallArgs(currName:String, argc:Int) {
		var doc:GmlFuncDoc = tools.JsTools.orx(
			GmlAPI.gmlDoc[currName],
			GmlAPI.extDoc[currName],
			GmlAPI.stdDoc[currName]
		);
		if (doc == null) {
			var lm = editor.lambdas[context];
			if (lm != null) doc = lm.docs[currName];
		}
		do {
			var minArgs:Int, maxArgs:Int;
			if (doc != null) {
				minArgs = doc.minArgs;
				maxArgs = doc.maxArgs;
			} else {
				// perhaps it's a hidden extension function? we don't add them to extDoc
				minArgs = GmlAPI.extArgc[currName];
				if (minArgs == null) {
					if (optRequireFunctions) {
						addWarning('`$currName` doesn\'t seem to be a valid function');
					}
					continue;
				}
				if (minArgs < 0) {
					minArgs = 0;
					maxArgs = 0x7fffffff;
				} else maxArgs = minArgs;
			}
			//
			if (argc < minArgs) {
				if (maxArgs == minArgs) {
					addError('Not enough arguments for $currName (expected $minArgs, got $argc)');
				} else if (maxArgs >= 0x7fffffff) {
					addError('Not enough arguments for $currName (expected $minArgs+, got $argc)');
				} else {
					addError('Not enough arguments for $currName (expected $minArgs..$maxArgs, got $argc)');
				}
			} else if (argc > maxArgs) {
				if (minArgs == maxArgs) {
					addError('Too many arguments for $currName (expected $maxArgs, got $argc)');
				} else {
					addError('Not enough arguments for $currName (expected $minArgs..$maxArgs, got $argc)');
				}
			}
		} while (false);
	}
	
	var readExpr_currKind:GmlLinterKind;
	function readExpr(oldDepth:Int, flags:GmlLinterReadFlags = None, ?_nk:GmlLinterKind):FoundError {
		var newDepth = oldDepth + 1;
		var q = reader;
		var nk:GmlLinterKind = nextOr(_nk);
		//
		inline function invalid():FoundError {
			return __readExpr_invalid(flags);
		}
		if (nk == KEOF) return invalid();
		//
		inline function hasFlag(flag:GmlLinterReadFlags):Bool {
			return flags.has(flag);
		}
		inline function isStat():Bool {
			return hasFlag(AsStat);
		}
		var wasStat = isStat();
		// the thing itself:
		var statKind = nk;
		var currKind = nk;
		var currName = nk == KIdent ? nextVal : null;
		//
		inline function checkConst():Void {
			if (currKind == KIdent && localKinds[currName] == KConst) {
				addWarning('Assigning to a `const` local `$currName`');
			}
		}
		//
		switch (nk) {
			case KNumber, KString, KUndefined: {
				
			};
			case KIdent: {
				if (hasFlag(HasPrefix)) checkConst();
				if (localKinds[currName] == KGhostVar) {
					addWarning('Trying to access a variable `$currName` outside of its scope');
				}
				if (isProperties && isStat()) {
					if (skipIf(peek() == KColon)) { // name:type
						rc(readCheckSkip(KIdent, "variable type"));
						if (skipIf(peek() == KLT)) {
							// we know that it's valid or you wouldn't make it here
							var depth = 1;
							while (q.loop) {
								switch (next()) {
									case KLT: depth++;
									case KGT: if (--depth <= 0) break;
									default:
								}
							}
						}
					}
				}
			};
			case KParOpen: {
				rc(readExpr(newDepth));
				if (next() != KParClose) return readExpect("a `)`");
			};
			case KNot, KBitNot, KNew: {
				rc(readExpr(newDepth));
			};
			case KInc, KDec: {
				rc(readExpr(newDepth, HasPrefix));
			};
			case KSqbOpen: rc(readArgs(newDepth, true) < 0);
			case KLambda: rc(readLambda(newDepth));
			case KFunction: rc(readLambda(newDepth, true));
			case KCubOpen: { // { fd1: v1, fd2: v2 }
				if (skipIf(peek() == KCubClose)) {
					// empty!
				} else while (q.loop) {
					switch (next()) {
						case KIdent, KString: { };
						default: return readExpect("a field name");
					}
					rc(readCheckSkip(KColon, "a `:` between key-value pair in {}"));
					rc(readExpr(newDepth));
					switch (peek()) {
						case KCubClose: skip(); break;
						case KComma: skip();
						default: return readExpect("a `,` or a `}` after a key-value pair in {}");
					}
				}
			};
			default: {
				if (nk.isUnOp()) {
					rc(readExpr(newDepth));
				}
				else return invalid();
			};
		}
		// suffixes:
		while (q.loop) {
			nk = peek();
			switch (nk) {
				case KSet: {
					if (isStat()) {
						checkConst();
						skip();
						flags.remove(AsStat);
						statKind = KSet;
						rc(readExpr(newDepth));
					} else {
						if (hasFlag(NoOps)) break;
						if (optNoSingleEqu) {
							addWarning("Using single `=` as a comparison operator");
						}
						skip();
						rc(readOps(newDepth));
						flags.add(NoSfx);
					}
				};
				case KParOpen: { // fn(...)
					if (!currKind.canCall()) return readError('Expression ${currKind.getName()} is not callable');
					if (hasFlag(NoSfx)) return readError("Can't call this");
					skip();
					statKind = KCall;
					var argc = readArgs(newDepth, false);
					rc(argc < 0);
					if (currKind == KIdent && currName != null) {
						checkCallArgs(currName, argc);
					}
				};
				case KInc, KDec: { // x++, x--
					if (hasFlag(NoSfx)) break;
					if (!currKind.canPostfix()) break;
					checkConst();
					skip();
					statKind = currKind = nk;
				};
				case KDot: { // x.y
					skip();
					rc(readCheckSkip(KIdent, "field name after `.`"));
					currKind = KField;
				};
				case KSqbOpen: { // x[i], x[?i], etc.
					skip();
					switch (peek()) {
						case KQMark, KOr: {
							skip();
							rc(readExpr(newDepth));
						};
						case KHash: {
							skip();
							rc(readExpr(newDepth));
							rc(readCheckSkip(KComma, "a comma before second index"));
							rc(readExpr(newDepth));
						};
						case KAtSign: {
							skip();
							rc(readExpr(newDepth));
							if (skipIf(peek() == KComma)) rc(readExpr(newDepth));
						};
						default: {
							rc(readExpr(newDepth));
							if (skipIf(peek() == KComma)) rc(readExpr(newDepth));
						};
					}
					rc(readCheckSkip(KSqbClose, "a closing `]` in array access"));
					currKind = KArray;
				};
				case KLiveIn: { // field in object
					if (hasFlag(NoOps)) break;
					skip();
					rc(readExpr(newDepth));
					currKind = KLiveIn;
				};
				case KNot: { // field not in object
					if (hasFlag(NoOps) || keywords["in"] == null) break;
					seqStart.setTo(reader);
					skip();
					if (!skipIf(peek() == KLiveIn)) {
						reader.setTo(seqStart);
						break;
					}
					rc(readExpr(newDepth));
					currKind = KLiveIn;
				};
				case KQMark: { // x ? y : z
					if (hasFlag(NoOps)) break;
					skip();
					rc(readExpr(newDepth));
					rc(readCheckSkip(KColon, "a colon in a ?: operator"));
					rc(readExpr(newDepth));
					currKind = KQMark;
				};
				default: {
					if (nk.isSetOp()) {
						if (!isStat()) return readError("Can't use " + nextDump() + " here.");
						checkConst();
						skip();
						currKind = statKind = KSet;
						rc(readExpr(newDepth));
						flags.add(NoSfx);
					}
					else if (nk.isBinOp()) {
						if (hasFlag(NoOps)) break;
						skip();
						rc(readOps(newDepth));
						flags.add(NoSfx);
					}
					else break;
				};
			}
		}
		//
		if (wasStat && !statKind.isStat()) {
			nextKind = statKind;
			nextVal = "";
			return readExpect("a statement");
		}
		readExpr_currKind = currKind;
		return false;
	}
	
	function discardBlockScopes(newDepth:Int):Void {
		while (localNamesPerDepth.length > newDepth) {
			var arr = localNamesPerDepth.pop();
			if (arr != null) {
				for (name in arr) localKinds[name] = KGhostVar;
			}
		}
	}
	
	var canBreak = false;
	var canContinue = false;
	function readLoopStat(oldDepth:Int, flags:GmlLinterReadFlags = None):FoundError {
		var _canBreak = canBreak;
		var _canContinue = canContinue;
		canBreak = true;
		canContinue = true;
		var result = readStat(oldDepth + 1, flags);
		canBreak = _canBreak;
		canContinue = _canContinue;
		return result;
	}
	
	function readSwitch(oldDepth:Int):FoundError {
		var newDepth = oldDepth + 1;
		rc(readCheckSkip(KCubOpen, "an opening `{` for switch-block"));
		//
		var isInCase = false;
		inline function resetCase():Void {
			if (isInCase) {
				if (optBlockScopedCase) discardBlockScopes(newDepth);
				isInCase = false;
			}
		}
		//
		seqStart.setTo(reader);
		var hasDefault = false;
		var q = reader;
		while (q.loop) {
			switch (peek()) {
				case KCubClose: {
					skip();
					return false;
				};
				case KDefault: {
					skip();
					if (hasDefault) return readError("That's default-case redefinition");
					hasDefault = true;
					rc(readCheckSkip(KColon, "a colon after default-case"));
					resetCase();
				};
				case KCase: {
					skip();
					rc(readExpr(newDepth));
					rc(readCheckSkip(KColon, "a colon after a case"));
					resetCase();
				};
				default: {
					isInCase = true;
					rc(readStat(newDepth));
				};
			}
		}
		return readSeqStartError("Unclosed switch-block");
	}
	function readEnum(oldDepth:Int):FoundError {
		var newDepth = oldDepth + 1;
		rc(readCheckSkip(KIdent, "an enum name"));
		rc(readCheckSkip(KCubOpen, "an opening `{` for enum"));
		var seenComma = true;
		while (reader.loop) {
			switch (next()) {
				case KCubClose: return false;
				case KIdent: {
					if (!seenComma) return readExpect("a `,` or `}` in enum");
					var nk = peek();
					if (skipIf(nk == KSet)) {
						rc(readExpr(newDepth));
						nk = peek();
					}
					seenComma = skipIf(nk == KComma);
				};
				default: {
					return readExpect("an enum field or `}`");
				}
			}
		}
		return readSeqStartError("Unclosed {}");
	}
	function readLambda(oldDepth:Int, isFunc:Bool = false):FoundError {
		skipIf(peek() == KIdent);
		if (skipIf(peek() == KParOpen)) { // (...args)
			var depth = 1;
			while (reader.loop) {
				switch (next()) {
					case KParOpen: depth++;
					case KParClose: if (--depth <= 0) break;
					default:
				}
			}
		} else if (isFunc) return readExpect("function literal arguments");
		//
		if (isFunc && skipIf(peek() == KColon)) { // : 
			readCheckSkip(KIdent, "a parent type name");
			readCheckSkip(KParOpen, "opening bracket");
			rc(readArgs(oldDepth + 1, false) < 0);
		}
		if (isFunc && skipIf(peek() == KConstructor)) {
			// nothing else to do?
		}
		//
		var oldLocalNames = localNamesPerDepth;
		var oldLocalKinds = localKinds;
		localNamesPerDepth = [];
		localKinds = new Dictionary();
		rc(readStat(0));
		localNamesPerDepth = oldLocalNames;
		localKinds = oldLocalKinds;
		return false;
	}
	
	/**
	 * 
	 */
	function readStat(oldDepth:Int, flags:GmlLinterReadFlags = None, ?_nk:GmlLinterKind):FoundError {
		var newDepth = oldDepth + 1;
		var q = reader;
		var nk:GmlLinterKind = nextOr(_nk);
		var mainKind = nk;
		var z:Bool, z2:Bool, i:Int;
		inline function checkParens():Void {
			if (optRequireParentheses && readExpr_currKind != KParOpen) {
				addWarning("Expression is missing parentheses");
			}
		}
		switch (nk) {
			case KMFuncDecl, KMacro: {};
			case KArgs: {};
			case KEnum: rc(readEnum(newDepth));
			case KVar, KConst, KLet, KGlobalVar: {
				//z = nk == KArgs;
				seqStart.setTo(reader);
				var found = 0;
				while (q.loop) {
					nk = peek();
					//if (z && nk == KQMark) { skip(); nk = peek(); }
					if (!skipIf(nk == KIdent)) break;
					if (mainKind != KGlobalVar) {
						var name = nextVal;
						if (mainKind != KVar || optBlockScopedVar) {
							var lk = localKinds[name];
							if (lk != null && lk != KGhostVar) {
								addWarning('Redefinition of a variable `$name`');
							} else {
								var arr = localNamesPerDepth[oldDepth];
								if (arr == null) {
									arr = [];
									localNamesPerDepth[oldDepth] = arr;
								}
								arr.push(name);
							}
						}
						localKinds[name] = mainKind;
					}
					found++;
					//
					nk = peek();
					if (nk == KColon) { // `name:type`
						skip();
						nk = peek();
						rc(readCheckSkip(nk, "a type name"));
						nk = peek();
					}
					if (nk == KSet) { // `name = val`
						skip();
						rc(readExpr(newDepth));
					}
					if (!skipIf(peek() == KComma)) break;
				}
				if (found == 0) readSeqStartWarn("This `var` has no declarations.");
			};
			case KCubOpen: {
				z = false;
				seqStart.setTo(reader);
				while (q.loop) {
					if (skipIf(peek() == KCubClose)) {
						z = true;
						break;
					}
					rc(readStat(newDepth));
				}
				if (!z) return readSeqStartError("Unclosed {}");
			};
			case KSemico: {
				if (optRequireSemico) {
					addWarning("Stray semicolon");
				}
			};
			case KIf: {
				rc(readExpr(newDepth));
				checkParens();
				skipIf(peek() == KThen);
				if (skipIf(peek() == KSemico)) {
					return readError("You have a semicolon before your then-expression.");
				}
				rc(readStat(newDepth));
				if (skipIf(peek() == KElse)) rc(readStat(newDepth));
			};
			case KWhile, KRepeat, KWith: {
				rc(readExpr(newDepth));
				checkParens();
				rc(readLoopStat(newDepth));
			};
			case KDo: {
				rc(readLoopStat(newDepth));
				switch (next()) {
					case KUntil, KWhile: {
						rc(readExpr(newDepth));
						checkParens();
					};
					default: return readExpect("an `until` or `while` for a do-loop");
				}
			};
			case KFor: {
				if (next() != KParOpen) return readExpect("a `(` to open a for-loop");
				if (!skipIf(peek() == KSemico)) rc(readStat(newDepth));
				if (!skipIf(peek() == KSemico)) {
					rc(readExpr(newDepth));
					skipIf(peek() == KSemico);
				}
				if (!skipIf(peek() == KParClose)) {
					rc(readLoopStat(newDepth, NoSemico));
					if (next() != KParClose) return readExpect("a `)` to close a for-loop");
				}
				rc(readLoopStat(newDepth));
			};
			case KExit: {};
			case KReturn: {
				switch (peek()) {
					case KSemico, KCubClose: skip(); flags.add(NoSemico);
					default: rc(readExpr(newDepth));
				}
			};
			case KBreak: {
				if (!canBreak) addError("Can't use `break` here");
			};
			case KContinue: {
				if (!canContinue) addError("Can't use `continue` here");
			};
			case KSwitch: {
				z = canBreak;
				canBreak = true;
				rc(readExpr(newDepth));
				checkParens();
				if (readSwitch(newDepth)) {
					canBreak = z;
					return true;
				} else canBreak = z;
			};
			//
			case KLiveWait, KYield, KGoto, KThrow, KDelete: { // keyword <value>
				rc(readExpr(newDepth));// wait <time>
			}
			case KLabel: { // label <name>[:]
				switch (peek()) {
					case KIdent, KString: {
						skip();
					};
					default: return readExpect("a label name");
				}
				skipIf(peek() == KColon);
			};
			case KStatic: { // todo: checking
				rc(readExpr(newDepth, flags.with(AsStat)));
			};
			case KTry: {
				rc(readStat(newDepth));
				rc(readCheckSkip(KCatch, "a `catch` after a `try` block"));
				rc(readExpr(newDepth));
				rc(readStat(newDepth)); // catch-block
				if (skipIf(peek() == KFinally)) {
					rc(readStat(newDepth));
				}
			};
			//
			case KLamDef: rc(readLambda(newDepth));
			default: {
				rc(readExpr(newDepth, flags.with(AsStat), nk));
			};
		}
		//
		if (skipIf(peek() == KSemico)) {
			// OK!
		} else if (optRequireSemico && mainKind.needSemico() && !flags.has(NoSemico) && q.peek(-1) != ";".code) {
			addWarning("Expected a semicolon after a statement (" + mainKind.getName() + ")");
		}
		//
		discardBlockScopes(newDepth);
		//
		return false;
	}
	
	/**
	 * 
	 * @return Whether there was a syntax error, among other things
	 */
	public function run(source:GmlCode, editor:EditCode, version:GmlVersion):FoundError {
		this.version = version;
		initKeywords();
		var q = reader = new GmlReaderExt(source.trimRight());
		this.name = q.name = editor.file.name;
		this.editor = editor;
		errorText = null;
		var ohno = false;
		while (q.loop) {
			var nk = next();
			if (nk == KEOF) break;
			if (readStat(0, None, nk)) {
				errors.push(new GmlLinterProblem(errorText, errorPos));
				ohno = true;
				break;
			}
		}
		//
		reader.clear();
		seqStart.clear();
		__peekReader.clear();
		return ohno;
	}
	
	
	public static function runFor(editor:EditCode, ?code:GmlCode):FoundError {
		var q = new GmlLinter();
		var session = editor.session;
		if (session.gmlErrorMarkers != null) {
			for (mk in session.gmlErrorMarkers) session.removeMarker(mk);
			session.gmlErrorMarkers.clear();
			session.clearAnnotations();
		}
		var t = Main.window.performance.now();
		if (code == null) code = session.getValue();
		var ohno = q.run(code, editor, gml.Project.current.version);
		t = (Main.window.performance.now() - t);
		//
		if (session.gmlErrorMarkers == null) session.gmlErrorMarkers = [];
		var annotations:Array<AceAnnotation> = [];
		function addMarker(text:String, pos:AcePos, isError:Bool) {
			var line = session.getLine(pos.row);
			var range = new AceRange(0, pos.row, line.length, pos.row);
			session.gmlErrorMarkers.push(
				session.addMarker(range, isError ? "ace_error-line" : "ace_warning-line", "fullLine")
			);
			annotations.push({
				row: pos.row, column: pos.column, type: isError ? "error" : "warning", text: text
			});
		}
		for (warn in q.warnings) addMarker(warn.text, warn.pos, false);
		for (error in q.errors) addMarker(error.text, error.pos, true);
		//
		var msg:String;
		if (q.warnings.length == 0 && q.errors.length == 0) {
			msg = "OK!";
		} else {
			if (ohno) {
				msg = "⛔"; // 🚔
			} else if (q.errors.length > 0) {
				msg = "🛑"; // 🚒
			} else msg = "⚠";
			if (q.errors.length > 0) {
				msg += q.errors.length + " error";
				if (q.errors.length != 1) msg += "s";
			}
			if (q.warnings.length > 0) {
				if (q.errors.length > 0) msg += ", ";
				msg += q.warnings.length + " warning";
				if (q.warnings.length != 1) msg += "s";
			}
			msg += "!";
		}
		msg += " (lint time: " + untyped (t.toFixed(2)) + "ms)";
		//
		Main.window.setTimeout(function() {
			var statusBar = Main.aceEditor.statusBar;
			statusBar.ignoreUntil = Main.window.performance.now() + statusBar.delayTime + 50;
			statusBar.setText(msg);
		}, 50);
		session.setAnnotations(annotations);
		return ohno;
	}
}

class GmlLinterProblem {
	public var text:String;
	public var pos:AcePos;
	public function new(text:String, pos:AcePos) {
		this.text = text;
		this.pos = pos;
	}
}
