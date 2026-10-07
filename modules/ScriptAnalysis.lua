--[[
	Script Analysis Module

	Pure Luau, no Roblox APIs (so tests can run it under Lune). A tolerant Luau lexer and parser,
	plus what the Script Viewer builds on it: outline, call graph, remote calls, rename, flowchart
	graphs with a layered layout, and a line diff.
]]

local function initDeps(data)
end

local function initAfterMain()
end

local function main()
	local A = {}

	local keywords = {}
	for word in ("and break do else elseif end false for function if in local nil not or repeat return then true until while"):gmatch("%a+") do
		keywords[word] = true
	end

	local remoteMethods = {FireServer = true, InvokeServer = true}
	local httpMethods = {HttpGet = true, HttpPost = true, HttpGetAsync = true, HttpPostAsync = true, RequestAsync = true, GetAsync = true, PostAsync = true}
	local httpFunctions = {request = true, http_request = true}
	local listenMethods = {Connect = true, Once = true, Wait = true, ConnectParallel = true}
	local compoundOps = {["+="] = true, ["-="] = true, ["*="] = true, ["/="] = true, ["%="] = true, ["^="] = true, ["..="] = true, ["//="] = true}

	----------------------------------------------------------------------------------------------
	-- Lexer. Parallel arrays: type, value, start/end byte, start/end line. Comments are skipped.
	----------------------------------------------------------------------------------------------

	local ops3 = {["..."] = true, ["..="] = true, ["//="] = true}
	local ops2 = {}
	for op in ("== ~= <= >= .. :: -> += -= *= /= %= ^= //"):gmatch("%S+") do
		ops2[op] = true
	end

	local function lex(src)
		local find, sub, byte = string.find, string.sub, string.byte
		local len = #src
		local tt, tv, tp, te, tl, tel = {}, {}, {}, {}, {}, {}
		local n = 0
		local errs = {}

		local nl = {}
		for pos in src:gmatch("()\n") do
			nl[#nl + 1] = pos
		end
		local li = 1
		local function lineAt(pos) -- positions must be asked for in increasing order
			while nl[li] and nl[li] < pos do li += 1 end
			return li
		end

		local function push(t, v, s, e)
			n += 1
			tt[n], tv[n], tp[n], te[n] = t, v, s, e
			local l = lineAt(s)
			tl[n] = l
			tel[n] = e > s and lineAt(e) or l
		end

		-- Closing quote index of the quoted string opening at i, and whether it was terminated.
		local function scanQuoted(i, q)
			local pat = q == 34 and '["\\\n]' or "['\\\n]"
			local j = i + 1
			while true do
				local p = find(src, pat, j)
				if not p then return len, false end
				local ch = byte(src, p)
				if ch == 92 then
					j = p + ((byte(src, p + 1) == 13 and byte(src, p + 2) == 10) and 3 or 2)
				elseif ch == 10 then
					return p - 1, false
				else
					return p, true
				end
			end
		end

		-- Interpolated strings can nest expressions that hold more strings and braces.
		local scanExpr
		local function scanBacktick(i)
			local j = i + 1
			while j <= len do
				local ch = byte(src, j)
				if ch == 96 then return j
				elseif ch == 92 then j += 2
				elseif ch == 123 then j = scanExpr(j + 1)
				else j += 1 end
			end
			return len
		end
		scanExpr = function(j) -- j is just after '{'; returns the index just after the matching '}'
			local depth = 1
			while j <= len do
				local ch = byte(src, j)
				if ch == 123 then
					depth += 1
					j += 1
				elseif ch == 125 then
					depth -= 1
					j += 1
					if depth == 0 then return j end
				elseif ch == 34 or ch == 39 then
					j = scanQuoted(j, ch) + 1
				elseif ch == 96 then
					j = scanBacktick(j) + 1
				else
					j += 1
				end
			end
			return j
		end

		local i = 1
		while i <= len do
			local c = byte(src, i)
			if c == 32 or c == 9 or c == 10 or c == 13 then
				local _, e = find(src, "^[ \t\r\n]+", i)
				i = e + 1
			elseif c == 45 and byte(src, i + 1) == 45 then
				local _, e, eq = find(src, "^%-%-%[(=*)%[", i)
				if e then
					local _, ce = find(src, "]" .. eq .. "]", e + 1, true)
					i = (ce or len) + 1
				else
					i = find(src, "\n", i, true) or len + 1
				end
			elseif (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95 then
				local _, e = find(src, "^[%w_]+", i)
				local word = sub(src, i, e)
				push(keywords[word] and "kw" or "name", word, i, e)
				i = e + 1
			elseif (c >= 48 and c <= 57) or (c == 46 and (byte(src, i + 1) or 0) >= 48 and (byte(src, i + 1) or 0) <= 57) then
				local s, e = find(src, "^0[xX][%x_]+", i)
				if not s then s, e = find(src, "^0[bB][01_]+", i) end
				if not s then
					s, e = find(src, "^[%d_]*%.?[%d_]*", i)
					local _, e2 = find(src, "^[eE][%+%-]?[%d_]+", e + 1)
					e = e2 or e
				end
				push("num", sub(src, i, e), i, e)
				i = e + 1
			elseif c == 34 or c == 39 then
				local e, ok = scanQuoted(i, c)
				if not ok then errs[#errs + 1] = {line = lineAt(i), msg = "unfinished string"} end
				push("str", sub(src, i + 1, ok and e - 1 or e), i, e)
				i = e + 1
			elseif c == 96 then
				local e = scanBacktick(i)
				push("istr", sub(src, i + 1, (e > i and byte(src, e) == 96) and e - 1 or e), i, e)
				i = e + 1
			elseif c == 91 then
				local _, e, eq = find(src, "^%[(=*)%[", i)
				if e then
					local _, ce = find(src, "]" .. eq .. "]", e + 1, true)
					local last = ce or len
					push("str", sub(src, e + 1, ce and ce - #eq - 2 or len), i, last)
					i = last + 1
				else
					push("op", "[", i, i)
					i += 1
				end
			else
				local three, two = sub(src, i, i + 2), sub(src, i, i + 1)
				if ops3[three] then
					push("op", three, i, i + 2)
					i += 3
				elseif ops2[two] then
					push("op", two, i, i + 1)
					i += 2
				else
					push("op", sub(src, i, i), i, i)
					i += 1
				end
			end
		end

		local count = n
		n += 1
		tt[n], tv[n], tp[n], te[n] = "eof", "", len + 1, len
		tl[n] = lineAt(len + 1)
		tel[n] = tl[n]
		return {src = src, tt = tt, tv = tv, tp = tp, te = te, tl = tl, tel = tel, n = count, nl = nl, errs = errs}
	end

	----------------------------------------------------------------------------------------------
	-- Text helpers
	----------------------------------------------------------------------------------------------

	-- Source text of tokens s..e, whitespace collapsed to single spaces and cut to max characters.
	function A.Text(R, s, e, max)
		local from = R.tp[s]
		local to = R.te[e] or from
		if max then to = math.min(to, from + max * 4) end
		local text = R.src:sub(from, to):gsub("%s+", " ")
		if max and #text > max then text = text:sub(1, max - 3) .. "..." end
		return text
	end

	-- Trimmed text of one source line (1-based).
	function A.LineText(R, line)
		local nl = R.nl
		local from = line == 1 and 1 or (nl[line - 1] and nl[line - 1] + 1)
		if not from then return "" end
		local to = (nl[line] or (#R.src + 1)) - 1
		return (R.src:sub(from, to):match("^%s*(.-)%s*$"))
	end

	function A.LineStart(R, line)
		return line == 1 and 1 or (R.nl[line - 1] and R.nl[line - 1] + 1)
	end

	local escapes = {n = "\n", t = "\t", r = "\r", a = "\a", b = "\b", f = "\f", v = "\v"}
	local function decodeEscapes(s)
		if not s:find("\\", 1, true) then return s end
		local out, i, len = {}, 1, #s
		while i <= len do
			if s:sub(i, i) ~= "\\" then
				local j = s:find("\\", i, true) or len + 1
				out[#out + 1] = s:sub(i, j - 1)
				i = j
			else
				local d = s:sub(i + 1, i + 1)
				local num = s:match("^%d%d?%d?", i + 1)
				if num then
					out[#out + 1] = string.char(math.min(255, tonumber(num)))
					i += 1 + #num
				elseif d == "x" and s:match("^%x%x", i + 2) then
					out[#out + 1] = string.char(tonumber(s:sub(i + 2, i + 3), 16))
					i += 4
				elseif d == "u" and s:match("^{%x+}", i + 2) then
					local hex = s:match("^{(%x+)}", i + 2)
					local ok, ch = pcall(utf8.char, tonumber(hex, 16))
					out[#out + 1] = ok and ch or "?"
					i += 4 + #hex
				elseif d == "z" then
					i += 2 + #s:match("^%s*", i + 2)
				else
					out[#out + 1] = escapes[d] or d
					i += 2
				end
			end
		end
		return table.concat(out)
	end

	-- Value of a string token (escapes decoded for quoted strings).
	function A.StringValue(R, ti)
		local q = R.src:sub(R.tp[ti], R.tp[ti])
		if q == '"' or q == "'" then return decodeEscapes(R.tv[ti]) end
		return R.tv[ti]
	end

	----------------------------------------------------------------------------------------------
	-- Parser. Tolerant: records errors and keeps going, so half-broken decompiler output still
	-- gives an outline and flowcharts. Tracks local scopes so rename/find-references are exact.
	----------------------------------------------------------------------------------------------

	local binPrio = {
		["or"] = {1, 1}, ["and"] = {2, 2},
		["<"] = {3, 3}, [">"] = {3, 3}, ["<="] = {3, 3}, [">="] = {3, 3}, ["~="] = {3, 3}, ["=="] = {3, 3},
		[".."] = {5, 4}, ["+"] = {6, 6}, ["-"] = {6, 6},
		["*"] = {7, 7}, ["/"] = {7, 7}, ["//"] = {7, 7}, ["%"] = {7, 7},
		["^"] = {10, 9},
	}
	local UNARY_PRIO = 8

	local simpleStatements = {Local = true, Assign = true, Compound = true, CallStat = true, ExprStat = true, Return = true}

	local function parse(lx)
		local tt, tv, tp, te, tl, tel, n = lx.tt, lx.tv, lx.tp, lx.te, lx.tl, lx.tel, lx.n
		local p = 1
		local errors = {}
		for _, e in ipairs(lx.errs) do errors[#errors + 1] = e end
		local symAt, globals, allSyms, calls, functions = {}, {}, {}, {}, {}
		local writes, loops, members = {}, {}, {} -- assigned name tokens; for statements; field and method name tokens -> the node using them
		local fn, scope
		local R = {src = lx.src, tt = tt, tv = tv, tp = tp, te = te, tl = tl, tel = tel, n = n, nl = lx.nl}

		local function err(msg)
			if #errors < 200 then errors[#errors + 1] = {line = tl[p] or tl[n] or 1, msg = msg} end
		end
		local function adv() if p <= n then p += 1 end end
		local function isop(v) return tt[p] == "op" and tv[p] == v end
		local function iskw(v) return tt[p] == "kw" and tv[p] == v end
		local function acceptop(v)
			if isop(v) then adv() return true end
			return false
		end
		local function expectop(v)
			if isop(v) then adv() return true end
			err("expected '" .. v .. "' near '" .. tostring(tv[p]) .. "'")
			return false
		end
		local function expectkw(v)
			if iskw(v) then adv() return true end
			err("expected '" .. v .. "' near '" .. tostring(tv[p]) .. "'")
			return false
		end
		local function expectname()
			if tt[p] == "name" then
				local ti = p
				adv()
				return ti
			end
			err("expected name near '" .. tostring(tv[p]) .. "'")
			return nil
		end
		local function blockEnds()
			local t, v = tt[p], tv[p]
			return t == "eof" or (t == "kw" and (v == "end" or v == "else" or v == "elseif" or v == "until"))
		end

		-- Types are skipped, not modelled.
		local skipType
		local function skipBalanced(open, close)
			local depth = 0
			repeat
				if isop(open) then depth += 1 elseif isop(close) then depth -= 1 end
				adv()
			until depth <= 0 or tt[p] == "eof"
		end
		skipType = function()
			local function primary()
				if isop("<") then skipBalanced("<", ">") end
				if isop("(") then
					skipBalanced("(", ")")
					if isop("->") then
						adv()
						skipType()
					end
				elseif isop("{") then
					skipBalanced("{", "}")
				elseif tt[p] == "name" or iskw("nil") or iskw("true") or iskw("false") then
					local isTypeof = tv[p] == "typeof"
					adv()
					if isTypeof and isop("(") then
						skipBalanced("(", ")")
						return
					end
					while isop(".") do
						adv()
						if tt[p] == "name" then adv() end
					end
					if isop("<") then skipBalanced("<", ">") end
				elseif tt[p] == "str" then
					adv()
				else
					err("bad type near '" .. tostring(tv[p]) .. "'")
				end
			end
			primary()
			while true do
				if isop("?") or isop("...") then
					adv()
				elseif isop("|") or isop("&") then
					adv()
					primary()
				elseif isop("->") then
					adv()
					skipType()
				else
					break
				end
			end
		end

		-- Scopes and symbols
		local function pushScope()
			scope = {parent = scope, names = {}, list = {}}
		end
		local function popScope()
			local last = p - 1
			for _, sym in ipairs(scope.list) do sym.e = last end
			scope = scope.parent
		end
		local function declare(ti)
			local sym = {name = tv[ti], decl = ti, refs = {}, fn = nil, s = p}
			scope.names[sym.name] = sym
			scope.list[#scope.list + 1] = sym
			symAt[ti] = sym
			allSyms[#allSyms + 1] = sym
			return sym
		end
		local function resolve(ti)
			local name = tv[ti]
			local sc = scope
			while sc do
				local sym = sc.names[name]
				if sym then
					sym.refs[#sym.refs + 1] = ti
					symAt[ti] = sym
					return sym
				end
				sc = sc.parent
			end
			local g = globals[name]
			if not g then
				g = {}
				globals[name] = g
			end
			g[#g + 1] = ti
			return nil
		end

		local parseBlock, parseExpr, parseStatement, parseTable

		local function parseExprList()
			local list = {parseExpr()}
			while acceptop(",") do list[#list + 1] = parseExpr() end
			return list
		end

		local function parseFuncBody(startTok, name, isMethod)
			local f = {k = "Function", s = startTok, params = {}, name = name, parent = fn, children = {}, depth = fn and fn.depth + 1 or 0, notable = 0}
			functions[#functions + 1] = f
			if fn then fn.children[#fn.children + 1] = f end
			local savedFn = fn
			fn = f
			pushScope()
			if isMethod then
				local sym = {name = "self", refs = {}, s = p}
				scope.names.self = sym
				scope.list[#scope.list + 1] = sym
			end
			if isop("<") then skipBalanced("<", ">") end
			if expectop("(") then
				while not isop(")") and tt[p] ~= "eof" do
					if isop("...") then
						f.vararg = true
						adv()
						if isop(":") then
							adv()
							skipType()
						end
					elseif tt[p] == "name" then
						local ti = p
						adv()
						f.params[#f.params + 1] = ti
						declare(ti)
						if isop(":") then
							adv()
							skipType()
						end
					else
						err("bad parameter near '" .. tostring(tv[p]) .. "'")
						break
					end
					if not acceptop(",") then break end
				end
				expectop(")")
			end
			if isop(":") then
				adv()
				skipType()
			end
			f.body = parseBlock()
			popScope()
			expectkw("end")
			f.e = p - 1
			f.line1 = tl[startTok]
			f.line2 = tel[f.e]
			fn = savedFn
			return f
		end

		local function classifyCall(node)
			local m = node.method and tv[node.method]
			local kind
			if m then
				if remoteMethods[m] then kind = "remote" elseif httpMethods[m] then kind = "http" end
			elseif node.fn.k == "Name" then
				local name = tv[node.fn.s]
				if httpFunctions[name] then kind = "http" elseif name == "loadstring" then kind = "dynamic" end
			end
			if kind then
				node.kind = kind
				fn.notable += 1
				fn.lastKind = kind
			end
		end

		local function parseCallArgs()
			if isop("(") then
				adv()
				local args = {}
				if not isop(")") then args = parseExprList() end
				expectop(")")
				return args
			elseif tt[p] == "str" or tt[p] == "istr" then
				local s = p
				adv()
				return {{k = tt[s] == "str" and "String" or "Interp", s = s, e = s}}
			elseif isop("{") then
				return {parseTable()}
			end
			err("function arguments expected near '" .. tostring(tv[p]) .. "'")
			return {}
		end

		local function parsePrimary()
			local s = p
			if tt[p] == "name" then
				adv()
				return {k = "Name", s = s, e = s, sym = resolve(s)}
			elseif isop("(") then
				adv()
				local inner = parseExpr()
				expectop(")")
				return {k = "Paren", inner = inner, s = s, e = p - 1}
			end
			err("unexpected symbol near '" .. tostring(tv[p]) .. "'")
			return {k = "Error", s = s, e = s}
		end

		local function finishCall(node)
			node.e = p - 1
			node.ctxFn = fn
			calls[#calls + 1] = node
			for _, a in ipairs(node.args) do
				if a.k == "Function" and not a.name then a.hintCall = node end
			end
			classifyCall(node)
			return node
		end

		local function parseSuffixed()
			local e = parsePrimary()
			while true do
				if isop(".") then
					adv()
					local ti = expectname()
					e = {k = "Index", obj = e, name = ti, s = e.s, e = ti or p - 1}
					if ti then members[ti] = e end
				elseif isop("[") then
					adv()
					local key = parseExpr()
					expectop("]")
					e = {k = "Index", obj = e, key = key, s = e.s, e = p - 1}
				elseif isop(":") then
					adv()
					local ti = expectname()
					e = finishCall({k = "Call", fn = e, method = ti, args = parseCallArgs(), s = e.s})
					if ti then members[ti] = e end
				elseif isop("(") or isop("{") or tt[p] == "str" or tt[p] == "istr" then
					e = finishCall({k = "Call", fn = e, args = parseCallArgs(), s = e.s})
				else
					break
				end
			end
			return e
		end

		local function parseSimple()
			local t, v, s = tt[p], tv[p], p
			if t == "num" then
				adv()
				return {k = "Number", s = s, e = s}
			elseif t == "str" or t == "istr" then
				adv()
				return {k = t == "str" and "String" or "Interp", s = s, e = s}
			elseif t == "kw" then
				if v == "nil" or v == "true" or v == "false" then
					adv()
					return {k = v == "nil" and "Nil" or "Bool", s = s, e = s}
				elseif v == "function" then
					adv()
					return parseFuncBody(s, nil)
				elseif v == "if" then
					adv()
					parseExpr()
					expectkw("then")
					parseExpr()
					while iskw("elseif") do
						adv()
						parseExpr()
						expectkw("then")
						parseExpr()
					end
					expectkw("else")
					parseExpr()
					return {k = "IfExpr", s = s, e = p - 1}
				end
			elseif t == "op" then
				if v == "..." then
					adv()
					return {k = "Vararg", s = s, e = s}
				elseif v == "{" then
					return parseTable()
				end
			end
			return parseSuffixed()
		end

		local function parseSub(limit)
			local e
			local t, v = tt[p], tv[p]
			if (t == "kw" and v == "not") or (t == "op" and (v == "-" or v == "#")) then
				local s = p
				adv()
				local operand = parseSub(UNARY_PRIO)
				e = {k = "Unop", op = v, operand = operand, s = s, e = operand.e}
			else
				e = parseSimple()
				while isop("::") do
					adv()
					skipType()
					e = {k = "Cast", inner = e, s = e.s, e = p - 1}
				end
			end
			while true do
				local ot, ov = tt[p], tv[p]
				local prio = (ot == "op" or ot == "kw") and binPrio[ov]
				if not prio or prio[1] <= limit then break end
				adv()
				local r = parseSub(prio[2])
				e = {k = "Binop", op = ov, l = e, r = r, s = e.s, e = r.e}
			end
			return e
		end
		parseExpr = function() return parseSub(0) end

		parseTable = function()
			local s = p
			adv() -- {
			while not isop("}") and tt[p] ~= "eof" do
				local before = p
				if isop("[") then
					adv()
					parseExpr()
					expectop("]")
					expectop("=")
					parseExpr()
				elseif tt[p] == "name" and tt[p + 1] == "op" and tv[p + 1] == "=" then
					local key = p
					p += 2
					local val = parseExpr()
					if val.k == "Function" and not val.name then val.name = tv[key] end
				else
					parseExpr()
				end
				if not (acceptop(",") or acceptop(";")) then break end
				if p == before then adv() end
			end
			expectop("}")
			return {k = "Table", s = s, e = p - 1}
		end

		-- Statements
		local function parseIf()
			local st = {k = "If", s = p, clauses = {}}
			local function clause()
				local cs = p
				adv()
				local cond = parseExpr()
				local thenTok = p
				expectkw("then")
				pushScope()
				local body = parseBlock()
				popScope()
				st.clauses[#st.clauses + 1] = {s = cs, cond = cond, thenTok = thenTok, body = body}
			end
			clause()
			while iskw("elseif") do clause() end
			if iskw("else") then
				adv()
				pushScope()
				st.els = parseBlock()
				popScope()
			end
			expectkw("end")
			return st
		end

		local function parseWhile()
			local st = {k = "While", s = p}
			adv()
			st.cond = parseExpr()
			st.doTok = p
			expectkw("do")
			pushScope()
			st.body = parseBlock()
			popScope()
			expectkw("end")
			return st
		end

		local function parseRepeat()
			local st = {k = "Repeat", s = p}
			adv()
			pushScope()
			st.body = parseBlock()
			st.untilTok = p
			expectkw("until")
			st.cond = parseExpr()
			popScope()
			return st
		end

		local function parseFor()
			local st = {k = "NumFor", s = p}
			loops[#loops + 1] = st
			adv()
			local first = expectname()
			if isop("=") then
				st.names = {first}
				adv()
				parseExpr()
				expectop(",")
				parseExpr()
				if acceptop(",") then parseExpr() end
				st.doTok = p
				expectkw("do")
				pushScope()
				if first then declare(first) end
				st.body = parseBlock()
				popScope()
				expectkw("end")
				return st
			end
			st.k = "GenFor"
			local names = {first}
			if isop(":") then
				adv()
				skipType()
			end
			while acceptop(",") do
				names[#names + 1] = expectname()
				if isop(":") then
					adv()
					skipType()
				end
			end
			expectkw("in")
			st.names, st.iter = names, parseExprList()
			st.doTok = p
			expectkw("do")
			pushScope()
			for _, ti in pairs(names) do declare(ti) end
			st.body = parseBlock()
			popScope()
			expectkw("end")
			return st
		end

		local function parseFunctionStat()
			local s = p
			adv()
			local first = expectname()
			local text = first and tv[first] or "?"
			local sym = first and resolve(first)
			local method, dotted = false, false
			local written = first -- the name this statement assigns: the function's, or the last field of its path
			while isop(".") or isop(":") do
				local colon = isop(":")
				adv()
				local ti = expectname()
				text = text .. (colon and ":" or ".") .. (ti and tv[ti] or "?")
				dotted = true
				written = ti or written
				if colon then
					method = true
					break
				end
			end
			if written then writes[written] = true end
			local f = parseFuncBody(s, text, method)
			if sym and not dotted then sym.fn = f end
			return {k = "FunctionStat", s = s, name = text, fn = f, method = method, funcs = {f}}
		end

		local function parseLocal()
			local s = p
			adv()
			if iskw("function") then
				adv()
				local nameTok = expectname()
				local sym = nameTok and declare(nameTok)
				local f = parseFuncBody(s, nameTok and tv[nameTok] or nil)
				if sym then
					sym.fn = f
					sym.init = f
				end
				return {k = "LocalFunction", s = s, name = nameTok, fn = f, funcs = {f}}
			end
			local names = {}
			repeat
				local ti = expectname()
				if not ti then break end
				names[#names + 1] = ti
				if isop(":") then
					adv()
					skipType()
				end
			until not acceptop(",")
			local values = {}
			if acceptop("=") then values = parseExprList() end
			for i, ti in ipairs(names) do
				local sym = declare(ti)
				local val = values[i]
				if val then
					sym.init = val
					if val.k == "Function" then
						sym.fn = val
						val.name = val.name or tv[ti]
					end
				end
			end
			return {k = "Local", s = s, names = names, values = values}
		end

		local function parseReturn()
			local st = {k = "Return", s = p}
			adv()
			if not blockEnds() and not isop(";") then st.values = parseExprList() end
			return st
		end

		local function parseTypeStat()
			local s = p
			adv() -- 'type'
			expectname()
			if isop("<") then skipBalanced("<", ">") end
			expectop("=")
			skipType()
			return {k = "TypeStat", s = s}
		end

		-- Remembers the name an assignment writes to: the variable, or the field of a.b.c
		local function markWrite(e)
			local ti = e.k == "Name" and e.s or (e.k == "Index" and e.name)
			if ti then writes[ti] = true end
		end

		local function parseExprStatement()
			local s = p
			local e = parseSuffixed()
			if isop("=") or isop(",") then
				local targets = {e}
				while acceptop(",") do targets[#targets + 1] = parseSuffixed() end
				expectop("=")
				local values = parseExprList()
				for i, v in ipairs(values) do
					if v.k == "Function" and not v.name and targets[i] then v.name = A.Text(R, targets[i].s, targets[i].e, 60) end
				end
				for _, t in ipairs(targets) do markWrite(t) end
				return {k = "Assign", s = s, targets = targets, values = values}
			end
			if tt[p] == "op" and compoundOps[tv[p]] then
				adv()
				markWrite(e)
				return {k = "Compound", s = s, target = e, value = parseExpr()}
			end
			if e.k ~= "Call" then
				err("expression is not a statement")
				return {k = "ExprStat", s = s}
			end
			return {k = "CallStat", s = s, call = e}
		end

		local function continueFollows()
			local nt, nv = tt[p + 1], tv[p + 1]
			if nt == "op" then
				return not (nv == "=" or nv == "." or nv == ":" or nv == "(" or nv == "[" or nv == "," or nv == "{" or compoundOps[nv])
			end
			return nt ~= "str" and nt ~= "istr"
		end

		parseStatement = function()
			while isop("@") do -- attributes: @native, @checked, @[a, b]
				adv()
				if isop("[") then skipBalanced("[", "]") elseif tt[p] == "name" then adv() end
			end
			local t, v, s = tt[p], tv[p], p
			if t == "op" and v == ";" then
				adv()
				return nil
			end
			local childMark, notableMark = #fn.children, fn.notable
			local st
			if t == "kw" then
				if v == "if" then st = parseIf()
				elseif v == "while" then st = parseWhile()
				elseif v == "for" then st = parseFor()
				elseif v == "repeat" then st = parseRepeat()
				elseif v == "function" then st = parseFunctionStat()
				elseif v == "local" then st = parseLocal()
				elseif v == "return" then st = parseReturn()
				elseif v == "break" then
					adv()
					st = {k = "Break", s = s}
				elseif v == "do" then
					adv()
					pushScope()
					local body = parseBlock()
					popScope()
					expectkw("end")
					st = {k = "Do", s = s, body = body}
				end
			elseif t == "name" then
				if v == "continue" and continueFollows() then
					adv()
					st = {k = "Continue", s = s}
				elseif v == "type" and tt[p + 1] == "name" then
					st = parseTypeStat()
				elseif v == "export" and tt[p + 1] == "name" and tv[p + 1] == "type" then
					adv()
					st = parseTypeStat()
					st.s = s
				end
			end
			st = st or parseExprStatement()
			acceptop(";")
			st.e = p - 1
			st.line1 = tl[st.s]
			st.line2 = tel[st.e]
			if simpleStatements[st.k] then
				if #fn.children > childMark then
					local funcs = {}
					for i = childMark + 1, #fn.children do funcs[#funcs + 1] = fn.children[i] end
					st.funcs = funcs
				end
				if fn.notable > notableMark then st.kind = fn.lastKind end
			end
			return st
		end

		parseBlock = function()
			local b = {k = "Block", body = {}, s = p}
			while not blockEnds() do
				local before = p
				local st = parseStatement()
				if st then b.body[#b.body + 1] = st end
				if p == before then
					err("unexpected '" .. tostring(tv[p]) .. "'")
					adv()
				end
			end
			b.e = p - 1
			return b
		end

		-- Chunk
		local root = {k = "Function", s = 1, e = n, params = {}, vararg = true, children = {}, depth = 0, notable = 0, name = "<main>", line1 = 1, line2 = tl[n + 1] or 1}
		functions[1] = root
		fn = root
		pushScope()
		local body = {k = "Block", body = {}, s = 1}
		while true do
			local b = parseBlock()
			for _, st in ipairs(b.body) do body.body[#body.body + 1] = st end
			if tt[p] == "eof" then break end
			err("unexpected '" .. tostring(tv[p]) .. "'")
			adv()
		end
		body.e = n
		root.body = body
		popScope()

		R.root, R.functions, R.calls, R.symAt, R.syms, R.globals, R.errors = root, functions, calls, symAt, allSyms, globals, errors
		R.writes, R.loops, R.members = writes, loops, members
		return R
	end

	function A.Analyze(src)
		return parse(lex(src))
	end

	----------------------------------------------------------------------------------------------
	-- Queries
	----------------------------------------------------------------------------------------------

	function A.FunctionName(R, f)
		if f.name then return f.name end
		local c = f.hintCall
		if c then
			return A.Text(R, c.fn.s, c.fn.e, 40) .. (c.method and (":" .. R.tv[c.method]) or "") .. " callback"
		end
		return "anonymous"
	end

	function A.Signature(R, f)
		local ps = {}
		for _, ti in ipairs(f.params) do ps[#ps + 1] = R.tv[ti] end
		if f.vararg and f.parent then ps[#ps + 1] = "..." end
		return A.FunctionName(R, f) .. "(" .. table.concat(ps, ", ") .. ")"
	end

	function A.Outline(R)
		local out = {}
		for _, f in ipairs(R.functions) do
			out[#out + 1] = {fn = f, name = A.Signature(R, f), line1 = f.line1, line2 = f.line2, depth = f.depth}
		end
		return out
	end

	-- Innermost function containing a line (the main chunk if none).
	function A.FunctionAtLine(R, line)
		local best, span
		for _, f in ipairs(R.functions) do
			if f.parent and line >= f.line1 and line <= f.line2 then
				local s = f.line2 - f.line1
				if not best or s <= span then best, span = f, s end
			end
		end
		return best or R.root
	end

	-- Index of the last token that starts at or before a byte position, or nil.
	local function lastTokenFrom(R, pos)
		local lo, hi, best = 1, R.n, nil
		while lo <= hi do
			local mid = (lo + hi) // 2
			if R.tp[mid] <= pos then
				best = mid
				lo = mid + 1
			else
				hi = mid - 1
			end
		end
		return best
	end

	-- Token whose characters include the one at a (1-based line, 0-based column): nil for the spot just
	-- after a token, for blanks between tokens and for tokens that span lines (unlike TokenAt).
	function A.TokenAtCell(R, line, col)
		local from = A.LineStart(R, line)
		if not from then return nil end
		local pos = from + col
		local best = lastTokenFrom(R, pos)
		if best and pos <= R.te[best] and R.tl[best] == line and R.tel[best] == line then return best end
		return nil
	end

	-- Token under a (1-based line, 0-based column) position; a cursor just after a token counts.
	function A.TokenAt(R, line, col)
		local from = A.LineStart(R, line)
		if not from then return nil end
		local pos = from + col
		local best = lastTokenFrom(R, pos)
		if not best then return nil end
		-- right after an identifier, with punctuation touching it, the identifier is what the cursor is on
		if pos == R.tp[best] and best > 1 and R.te[best - 1] == pos - 1 and R.tt[best - 1] == "name" and R.tt[best] ~= "name" then
			return best - 1
		end
		return pos <= R.te[best] + 1 and best or nil
	end

	function A.TokenPos(R, ti)
		local line = R.tl[ti]
		return line, R.tp[ti] - A.LineStart(R, line)
	end

	-- Every occurrence of the symbol under a token, as sorted token indexes. exact is true for locals;
	-- globals and field names fall back to every identifier with the same text.
	function A.References(R, ti)
		local sym = R.symAt[ti]
		local list = {}
		if sym then
			list[1] = sym.decl
			for _, r in ipairs(sym.refs) do list[#list + 1] = r end
			table.sort(list)
			return list, true
		end
		if R.tt[ti] ~= "name" then return list, false end
		local text = R.tv[ti]
		for i = 1, R.n do
			if R.tt[i] == "name" and R.tv[i] == text and not R.symAt[i] then list[#list + 1] = i end
		end
		return list, false
	end

	-- The same occurrences as References, each marked as a write (a declaration or the target of an
	-- assignment, also x += 1 and function a.b()) or a read: {{tok, write}}, and whether the match is exact.
	function A.Accesses(R, ti)
		local list, exact = A.References(R, ti)
		local sym = R.symAt[ti]
		local out = {}
		for i, t in ipairs(list) do
			out[i] = {tok = t, write = R.writes[t] == true or (sym ~= nil and t == sym.decl)}
		end
		return out, exact
	end

	-- Where a name is defined: its declaration for locals, else a function with that name.
	function A.Definition(R, ti)
		local sym = R.symAt[ti]
		if sym and sym.decl then return sym.decl end
		if R.tt[ti] ~= "name" then return nil end
		local text = R.tv[ti]
		for _, f in ipairs(R.functions) do
			if f.name and f.name:match("[%w_]+$") == text then return f.s end
		end
		return nil
	end

	-- Whether a local can be renamed without capturing or shadowing anything. Returns the symbol, or nil and a reason.
	function A.CanRename(R, ti, newName)
		local sym = R.symAt[ti]
		if not sym or not sym.decl then return nil, "not a local variable" end
		if not newName:match("^[%a_][%w_]*$") then return nil, "not a valid name" end
		if keywords[newName] then return nil, "reserved word" end
		if newName == sym.name then return nil, "same name" end

		local function inside(s, lo, hi)
			if s.decl and s.decl >= lo and s.decl <= hi then return true end
			for _, r in ipairs(s.refs) do
				if r >= lo and r <= hi then return true end
			end
			return false
		end
		for _, other in ipairs(R.syms) do
			if other ~= sym and other.name == newName and other.e and sym.e then
				if inside(sym, other.decl, other.e) or inside(other, sym.decl, sym.e) then
					return nil, "'" .. newName .. "' is already used in that scope"
				end
			end
		end
		for _, gi in ipairs(R.globals[newName] or {}) do
			if gi >= sym.decl and gi <= (sym.e or R.n) then return nil, "'" .. newName .. "' is a global used in that scope" end
		end
		return sym
	end

	-- The source with tokens replaced: names[token index] = new text.
	local function splice(R, names)
		local toks = {}
		for t in pairs(names) do toks[#toks + 1] = t end
		table.sort(toks)
		local pieces, last = {}, 1
		for _, t in ipairs(toks) do
			pieces[#pieces + 1] = R.src:sub(last, R.tp[t] - 1)
			pieces[#pieces + 1] = names[t]
			last = R.te[t] + 1
		end
		pieces[#pieces + 1] = R.src:sub(last)
		return table.concat(pieces)
	end

	-- Renames a local symbol. Returns the new source and the declaration's {line, col}, or nil and a reason.
	function A.Rename(R, ti, newName)
		local sym, reason = A.CanRename(R, ti, newName)
		if not sym then return nil, reason end

		local names = {}
		for _, t in ipairs(A.References(R, ti)) do names[t] = newName end
		local line, col = A.TokenPos(R, sym.decl)
		return splice(R, names), {line = line, col = col}
	end

	-- Applies several renames ({tok, name}) to one analysis result, skipping the ones that clash.
	-- Returns the new source and how many were applied.
	function A.RenameMany(R, list)
		local names, applied = {}, 0
		for _, r in ipairs(list) do
			if A.CanRename(R, r.tok, r.name) then
				for _, t in ipairs((A.References(R, r.tok))) do names[t] = r.name end
				applied += 1
			end
		end
		return splice(R, names), applied
	end

	----------------------------------------------------------------------------------------------
	-- Suggested names for the locals a decompiler called v12, p3 or l_Players_0
	----------------------------------------------------------------------------------------------

	local generatedPatterns = {"^[vplu]%d+$", "^l_.+_%d+$", "^arg%d+$", "^var%d+$", "^local%d+$", "^upval%d+$", "^reg%d+$"}

	-- Whether a name is one a decompiler made up, so nothing is lost by changing it.
	function A.LooksGenerated(name)
		for _, pat in ipairs(generatedPatterns) do
			if name:match(pat) then return true end
		end
		return false
	end

	-- LocalPlayer -> localPlayer, GUIObject -> guiObject, HRP -> hrp
	local function camel(s)
		local up = s:match("^%u+")
		if not up then return s end
		if #up == #s then return s:lower() end
		if #up == 1 then return s:sub(1, 1):lower() .. s:sub(2) end
		return up:sub(1, -2):lower() .. s:sub(#up)
	end

	-- A string as a variable name ("Walk Speed" -> walkSpeed), or nil when nothing usable is left.
	local function wordName(s)
		s = s:gsub("[^%w_]+(%w?)", function(c) return c:upper() end)
		if s == "" or #s > 28 or s:match("^%d") or keywords[s] then return nil end
		return camel(s)
	end

	-- children -> child, enemies -> enemy, items -> item; nil for a word that is not a plural
	local function singular(w)
		local l = w:lower()
		if l == "children" then return "child" end
		if l == "people" then return "person" end
		if #w > 3 and l:sub(-3) == "ies" then return w:sub(1, -4) .. "y" end
		if #w > 4 and (l:match("sses$") or l:match("shes$") or l:match("ches$") or l:match("[xz]es$")) then return w:sub(1, -3) end
		if #w > 2 and l:sub(-1) == "s" and l:sub(-2) ~= "ss" then return w:sub(1, -2) end
		return nil
	end

	local childGetters = {WaitForChild = true, FindFirstChild = true, FindFirstChildOfClass = true, FindFirstChildWhichIsA = true, FindFirstAncestor = true, FindFirstAncestorOfClass = true, FindFirstAncestorWhichIsA = true, GetAttribute = true}

	-- The word an expression is called by: Items in workspace.Items, Players in GetService("Players"), the
	-- original name inside l_Items_0. nil for anything the decompiler made up.
	local function lastWord(R, e)
		local k = e.k
		if k == "Name" then
			local name = R.tv[e.s]
			local inner = name:match("^l_(.+)_%d+$")
			if inner and inner:match("^[%a_][%w_]*$") then return inner end
			return (not A.LooksGenerated(name)) and name or nil
		elseif k == "Index" then
			return e.name and R.tv[e.name] or (e.key and e.key.k == "String" and A.StringValue(R, e.key.s)) or nil
		elseif k == "Call" and e.method then
			local m, arg = R.tv[e.method], e.args[1]
			if arg and arg.k == "String" and (m == "GetService" or childGetters[m]) then return A.StringValue(R, arg.s) end
		elseif k == "Paren" or k == "Cast" then
			return lastWord(R, e.inner)
		end
		return nil
	end

	-- A name for what an expression makes, and what it was taken from, or nil.
	local function exprName(R, e, depth)
		depth = depth or 0
		if depth > 4 then return nil end
		local k = e.k
		if k == "Paren" or k == "Cast" then return exprName(R, e.inner, depth + 1) end
		if k == "Binop" and (e.op == "or" or e.op == "and") then
			return exprName(R, e.l, depth + 1) or exprName(R, e.r, depth + 1)
		end
		if k == "Index" then
			local w = lastWord(R, e)
			local n = w and wordName(w)
			if not n then return nil end
			-- a service reached through game keeps its capital: game.Players
			local viaGame = e.obj.k == "Name" and R.tv[e.obj.s] == "game" and not R.symAt[e.obj.s]
			return (viaGame and w:match("^[%a_][%w_]*$")) and w or n, "." .. w
		end
		if k ~= "Call" then return nil end

		local arg = e.args[1]
		local str = arg and arg.k == "String" and A.StringValue(R, arg.s) or nil
		local m = e.method and R.tv[e.method]
		if m then
			if m == "GetService" and str and str:match("^[%a_][%w_]*$") then return str, ':GetService("' .. str .. '")' end
			if childGetters[m] and str then
				local n = wordName(str)
				return n, n and (":" .. m .. '("' .. str .. '")')
			end
			if m == "Connect" or m == "Once" or m == "ConnectParallel" then return "connection", ":" .. m .. "(...)" end
			if m == "GetPropertyChangedSignal" and str then
				local n = wordName(str)
				return n and (n .. "Changed"), ":" .. m .. '("' .. str .. '")'
			end
			if m == "Clone" then return "clone", ":Clone()" end
			if m == "InvokeServer" or m == "InvokeClient" then return "result", ":" .. m .. "(...)" end
			local thing = m:match("^Get(%u%w*)$")
			if thing then return camel(thing), ":" .. m .. "()" end
			return nil
		end

		local f = e.fn
		if f.k == "Index" and f.name and R.tv[f.name] == "new" and f.obj.k == "Name" and R.tv[f.obj.s] == "Instance" and str then
			local n = wordName(str)
			return n, n and ('Instance.new("' .. str .. '")')
		end
		if f.k == "Name" and not R.symAt[f.s] then
			local fname = R.tv[f.s]
			if fname == "require" and arg then
				local path = A.ResolvePath(R, arg)
				local last = path.steps and path.steps[#path.steps]
				if last == "Parent" then last = nil end
				last = last or lastWord(R, arg)
				if last and last:match("^[%a_][%w_]*$") and not keywords[last] then return last, "require(" .. last .. ")" end
			elseif fname == "setmetatable" then
				return "self", "setmetatable(...)"
			elseif fname == "tick" or fname == "time" then
				return "now", fname .. "()"
			end
		end
		return nil
	end

	-- What the items of a loop are called, from what it walks over: children of workspace.Enemies -> enemy
	local function elementName(R, e)
		if not e then return nil end
		if e.k == "Call" and e.method then
			local m = R.tv[e.method]
			if m == "GetChildren" or m == "GetDescendants" then
				local w = lastWord(R, e.fn)
				local one = w and singular(w)
				return (one and wordName(one)) or (m == "GetChildren" and "child" or "descendant")
			elseif m == "GetPlayers" then
				return "player"
			end
			local things = m:match("^Get(%u%w*)$")
			local one = things and singular(things)
			return one and wordName(one)
		end
		local w = lastWord(R, e)
		local one = w and singular(w)
		return one and wordName(one)
	end

	local loopCounters = {"i", "j", "k", "l", "m", "n"}

	-- Proposed renames for the locals that look made up by a decompiler: {{tok, sym, from, name, why}} in
	-- source order. Taken from what each local is set to (game:GetService("Players") -> Players,
	-- X:WaitForChild("Remote") -> remote, ...), from what a loop walks over, and, for the parameters of a
	-- callback given to Connect, from events(eventName, parameterCount) -> {names} (the Roblox API's own
	-- parameter names). Only names that can be used there without clashing are offered.
	function A.SuggestNames(R, events)
		local found = {} -- sym -> {names = {...}, why}
		local function propose(sym, name, why)
			if not (sym and sym.decl and name) or found[sym] or not A.LooksGenerated(sym.name) then return end
			local names = {}
			if type(name) == "table" then
				names = name
			else
				names[1] = name
				for n = 2, 9 do names[n] = name .. n end
			end
			found[sym] = {names = names, why = why}
		end

		for _, sym in ipairs(R.syms) do
			-- l_Players_0: the decompiler already says what it was
			local inner = sym.decl and sym.name:match("^l_(.+)_%d+$")
			if inner and inner:match("^[%a_][%w_]*$") and not keywords[inner] then propose(sym, inner, "named after what it holds") end
		end
		for _, sym in ipairs(R.syms) do
			if sym.init and sym.decl then
				local name, why = exprName(R, sym.init)
				propose(sym, name, why)
			end
		end

		for _, st in ipairs(R.loops) do
			local names = st.names or {}
			if st.k == "NumFor" then
				propose(names[1] and R.symAt[names[1]], loopCounters, "loop counter")
			else
				local it = st.iter and st.iter[1]
				local inner, keyName
				if it and it.k == "Call" and not it.method and it.fn.k == "Name" and not R.symAt[it.fn.s] and (R.tv[it.fn.s] == "pairs" or R.tv[it.fn.s] == "ipairs") then
					inner = it.args[1]
					keyName = R.tv[it.fn.s] == "ipairs" and "index" or "key"
				else
					inner = it
				end
				if keyName and names[1] then propose(R.symAt[names[1]], keyName, "key of " .. R.tv[it.fn.s]) end
				local value = names[2] and elementName(R, inner)
				if value then propose(R.symAt[names[2]], value, "item of the loop") end
			end
		end

		if events then
			for _, f in ipairs(R.functions) do
				local c = f.hintCall
				local m = c and c.method and R.tv[c.method]
				if (m == "Connect" or m == "Once" or m == "ConnectParallel") and c.fn.k == "Index" and c.fn.name and #f.params > 0 then
					local event = R.tv[c.fn.name]
					local names = events(event, #f.params)
					for i, ti in ipairs(f.params) do
						local n = names and names[i] and wordName(names[i])
						if n then propose(R.symAt[ti], n, ("parameter %d of %s"):format(i, event)) end
					end
				end
			end
		end

		local list = {}
		for _, sym in ipairs(R.syms) do
			local f = found[sym]
			if f then list[#list + 1] = {tok = sym.decl, sym = sym, from = sym.name, names = f.names, why = f.why} end
		end
		table.sort(list, function(a, b) return a.tok < b.tok end)

		local chosen, out = {}, {}
		for _, s in ipairs(list) do
			local pick
			for _, cand in ipairs(s.names) do
				local free = A.CanRename(R, s.tok, cand) ~= nil
				if free then
					for _, c in ipairs(chosen) do
						-- a scope that overlaps one already given this name
						if c.name == cand and c.sym.decl <= (s.sym.e or R.n) and s.tok <= (c.sym.e or R.n) then
							free = false
							break
						end
					end
				end
				if free then
					pick = cand
					break
				end
			end
			if pick then
				chosen[#chosen + 1] = {sym = s.sym, name = pick}
				out[#out + 1] = {tok = s.tok, sym = s.sym, from = s.from, name = pick, why = s.why}
			end
		end
		return out
	end

	----------------------------------------------------------------------------------------------
	-- From the source to the running script: which function a token is in, which constants and upvalues
	-- the running copy of that function has
	----------------------------------------------------------------------------------------------

	-- Name a function is known by (the last part of "Class:method" or "a.b.fn"), or nil when it has none.
	function A.ShortName(f)
		return f.name and f.name:match("[%w_]+$") or nil
	end

	-- How many parameters the running function has: a method takes self as well.
	function A.ParamCount(f)
		return #f.params + ((f.name and f.name:find(":", 1, true)) and 1 or 0)
	end

	-- First token inside a function's own scope: its parameters, else its body. What comes before (the
	-- name, "local function") belongs to the function around it.
	local function scopeStart(f)
		return f.params[1] or f.body.s
	end

	-- Innermost function (never the main chunk) whose parameters or body contain a token. Worked out for
	-- every token at the first call (a function that is nested inside another is listed after it and
	-- overwrites it), so asking again is a table lookup.
	function A.FunctionAtToken(R, ti)
		local map = R.fnMap
		if not map then
			map = {}
			for _, f in ipairs(R.functions) do
				if f.parent then
					for t = scopeStart(f), f.e do map[t] = f end
				end
			end
			R.fnMap = map
		end
		return map[ti]
	end

	-- First and last token that start on a line (1-based), or nil when none does.
	function A.TokensOnLine(R, line)
		local lo, hi, first = 1, R.n, nil
		while lo <= hi do
			local mid = (lo + hi) // 2
			if R.tl[mid] >= line then
				first = mid
				hi = mid - 1
			else
				lo = mid + 1
			end
		end
		if not first or R.tl[first] ~= line then return nil end
		local last = first
		while last < R.n and R.tl[last + 1] == line do last += 1 end
		return first, last
	end

	-- Value of a number token ("0x1F", "1_000", "0b101", "1e3"), or nil.
	function A.NumberValue(text)
		text = text:gsub("_", "")
		local bits = text:match("^0[bB]([01]+)$")
		return bits and tonumber(bits, 2) or tonumber(text)
	end

	-- What the running script's constants table would hold for a token, as a list of values: a string,
	-- a number (the compiler may have negated it) or the name of a global or field. nil for anything else.
	function A.ConstantValues(R, ti)
		local t = R.tt[ti]
		if t == "str" then return {A.StringValue(R, ti)} end
		if t == "name" and not R.symAt[ti] then return {R.tv[ti]} end
		if t == "num" then
			local v = A.NumberValue(R.tv[ti])
			if not v then return nil end
			if ti > 1 and R.tt[ti - 1] == "op" and R.tv[ti - 1] == "-" then return {v, -v} end
			return {v}
		end
		return nil
	end

	-- The constants a function's source spells out itself, not those of the functions inside it, as a
	-- set: strings, numbers and global and field names.
	function A.Literals(R, f)
		local set = {}
		local children, ci = f.children, 1
		local ti = scopeStart(f)
		while ti <= f.e do
			local c = children[ci]
			if c and ti >= scopeStart(c) then
				ti = c.e + 1 -- a function inside has constants of its own
				ci += 1
			else
				for _, v in ipairs(A.ConstantValues(R, ti) or {}) do set[v] = true end
				ti += 1
			end
		end
		return set
	end

	-- The function that uses a local from outside the one that declares it: the function around the token
	-- if it is used like that there, else the first function that does. nil when only the declaring
	-- function touches the local, so it is no upvalue.
	function A.UpvalueSite(R, ti)
		local sym = R.symAt[ti]
		if not sym or not sym.decl then return nil end
		local home = A.FunctionAtToken(R, sym.decl)
		local here = A.FunctionAtToken(R, ti)
		if here ~= home then return here end
		local sites = R.siteOf
		if not sites then
			sites = {}
			R.siteOf = sites
		end
		local site = sites[sym]
		if site == nil then
			site = false
			for _, ref in ipairs(sym.refs) do
				local user = A.FunctionAtToken(R, ref)
				if user and user ~= home then
					site = user
					break
				end
			end
			sites[sym] = site
		end
		return site or nil
	end

	-- Where a local probably is in the upvalue list of function f. Luau numbers upvalues in the order the
	-- code first uses them and keeps no names, so this counts the outside locals f's source mentions, in
	-- source order. An estimate: the compiler drops locals that are plain constants and evaluates the right
	-- side of an assignment before the left.
	function A.UpvalueIndex(R, f, sym)
		local from = scopeStart(f)
		local seen, count = {}, 0
		for ti = from, f.e do
			local s = R.symAt[ti]
			if s and not seen[s] then
				-- self has no declaring token: it belongs to the method that was being parsed when it was made
				local outside
				if s.decl then outside = s.decl < from or s.decl > f.e else outside = s.s < f.s or s.s > f.e end
				if outside then
					count += 1
					seen[s] = count
				end
			end
		end
		return seen[sym]
	end

	----------------------------------------------------------------------------------------------
	-- Remote calls and other interesting calls
	----------------------------------------------------------------------------------------------

	-- Resolves an expression like game:GetService("ReplicatedStorage").Remotes.Hit to path steps.
	-- Always returns a table with text; root ("game" or "script") and steps are set when it resolved.
	function A.ResolvePath(R, e, depth)
		depth = depth or 0
		local function raw() return {text = A.Text(R, e.s, e.e, 60)} end
		local function finish(root, steps)
			local text = table.concat(steps, ".")
			if root == "script" then text = text == "" and "script" or "script." .. text
			elseif text == "" then text = "game" end
			return {root = root, steps = steps, text = text}
		end
		local function extend(base, step)
			if not base or not base.root then return nil end
			local steps = table.move(base.steps, 1, #base.steps, 1, {})
			steps[#steps + 1] = step
			return finish(base.root, steps)
		end
		if depth > 8 then return raw() end

		if e.k == "Name" then
			local name = R.tv[e.s]
			local sym = R.symAt[e.s]
			if sym then
				-- ponytail: follows the declaring assignment only, not later reassignments
				local resolved = sym.init and sym.init ~= e and A.ResolvePath(R, sym.init, depth + 1)
				return resolved and resolved.root and resolved or raw()
			end
			if name == "game" then return finish("game", {}) end
			if name == "workspace" then return finish("game", {"Workspace"}) end
			if name == "script" then return finish("script", {}) end
			return raw()
		elseif e.k == "Paren" then
			return A.ResolvePath(R, e.inner, depth + 1)
		elseif e.k == "Index" then
			local key = e.name and R.tv[e.name] or (e.key and e.key.k == "String" and A.StringValue(R, e.key.s))
			return key and extend(A.ResolvePath(R, e.obj, depth + 1), key) or raw()
		elseif e.k == "Call" and e.method then
			local m = R.tv[e.method]
			local arg = e.args[1]
			if arg and arg.k == "String" and (m == "GetService" or m == "WaitForChild" or m == "FindFirstChild") then
				return extend(A.ResolvePath(R, e.fn, depth + 1), A.StringValue(R, arg.s)) or raw()
			end
		end
		return raw()
	end

	-- Calls worth surfacing: remote fire/invoke, remote listeners, http requests, loadstring.
	function A.Remotes(R)
		local out = {}
		for _, c in ipairs(R.calls) do
			local kind, method, receiver
			local mname = c.method and R.tv[c.method]
			if c.kind == "remote" then
				kind, method, receiver = "remote", mname, c.fn
			elseif c.kind then
				kind, method = c.kind, mname or R.tv[c.fn.s]
				receiver = mname and c.fn or nil
			elseif mname and listenMethods[mname] and c.fn.k == "Index" and c.fn.name and R.tv[c.fn.name] == "OnClientEvent" then
				kind, method, receiver = "listen", mname, c.fn.obj
			end
			if kind then
				local args = {}
				for i = 1, math.min(#c.args, 4) do args[i] = A.Text(R, c.args[i].s, c.args[i].e, 40) end
				out[#out + 1] = {kind = kind, method = method, line = R.tl[c.s], call = c, fn = c.ctxFn, args = args, argCount = #c.args, path = receiver and A.ResolvePath(R, receiver) or nil}
			end
		end
		table.sort(out, function(a, b) return a.line < b.line end)
		return out
	end

	----------------------------------------------------------------------------------------------
	-- Call graph: functions as nodes, static calls as edges. Anonymous callbacks hang off the
	-- function that hands them to something (Connect, spawn, ...); remote/http calls are leaves.
	----------------------------------------------------------------------------------------------

	local function shortIndex(R)
		if R.byShort then return R.byShort end
		local byShort = {}
		for _, f in ipairs(R.functions) do
			local short = f.name and f.name:match("[%w_]+$")
			if short then
				byShort[short] = byShort[short] or {}
				table.insert(byShort[short], f)
			end
		end
		R.byShort = byShort
		return byShort
	end

	-- Functions a call may reach: exactly the function for a local, otherwise every function with that
	-- name (nil when there are none, or too many to mean anything).
	function A.CallTargets(R, c)
		local byShort = shortIndex(R)
		local targets
		if c.method then
			targets = byShort[R.tv[c.method]]
		elseif c.fn.k == "Name" then
			local sym = R.symAt[c.fn.s]
			if sym then
				targets = sym.fn and {sym.fn} or nil
			else
				targets = byShort[R.tv[c.fn.s]]
			end
		elseif c.fn.k == "Index" and c.fn.name then
			targets = byShort[R.tv[c.fn.name]]
		end
		if targets and #targets <= 3 then return targets end
		return nil
	end

	function A.CallGraph(R, opts)
		local maxNodes = opts and opts.maxNodes or 300
		local nodes, edges, nodeOf, edgeOf = {}, {}, {}, {}
		local G = {nodes = nodes, edges = edges, mode = "calls", R = R}

		local function nodeFor(key, make)
			local nd = nodeOf[key]
			if not nd and #nodes < maxNodes then
				nd = make()
				nd.id = #nodes + 1
				nd.stmts, nd.funcs = {}, {}
				nodes[nd.id] = nd
				nodeOf[key] = nd
			end
			return nd
		end
		local function funcNode(f)
			return nodeFor(f, function()
				local isRoot = not f.parent
				return {kind = isRoot and "root" or "func", fn = f, label = isRoot and "script" or A.Signature(R, f), line1 = f.line1, line2 = f.line1}
			end)
		end
		local function addEdge(a, b, kind, label)
			if not a or not b or a == b then return end
			local key = a.id .. ">" .. b.id .. kind
			local e = edgeOf[key]
			if e then
				e.count += 1
			else
				e = {from = a.id, to = b.id, kind = kind, label = label, count = 1}
				edgeOf[key] = e
				edges[#edges + 1] = e
			end
		end

		for _, c in ipairs(R.calls) do
			for _, t in ipairs(A.CallTargets(R, c) or {}) do
				addEdge(funcNode(c.ctxFn), funcNode(t), "call")
			end
		end

		for _, f in ipairs(R.functions) do
			if f.hintCall and f.parent then
				local c = f.hintCall
				addEdge(funcNode(f.parent), funcNode(f), "def", c.method and R.tv[c.method] or nil)
			end
		end

		for _, r in ipairs(A.Remotes(R)) do
			if r.kind ~= "listen" then
				local label = r.method .. (r.path and ("\n" .. r.path.text) or "")
				local target = nodeFor(r.kind .. label, function()
					return {kind = r.kind, label = label, line1 = r.line, line2 = r.line}
				end)
				addEdge(funcNode(r.fn), target, r.kind)
			end
		end

		-- functions nobody calls and nothing calls are noise; keep only connected nodes
		local used = {}
		for _, e in ipairs(edges) do
			used[e.from], used[e.to] = true, true
		end
		local keep, remap, shown = {}, {}, 0
		for _, nd in ipairs(nodes) do
			if used[nd.id] or nd.kind == "root" then
				keep[#keep + 1] = nd
				remap[nd.id] = #keep
				if nd.kind == "func" then shown += 1 end
			end
		end
		for i, nd in ipairs(keep) do nd.id = i end
		for _, e in ipairs(edges) do
			e.from, e.to = remap[e.from], remap[e.to]
		end
		G.nodes = keep
		G.hidden = #R.functions - 1 - shown -- functions with no static calls in or out
		return G
	end

	-- How execution can get to a function: chains of {fn, line} from where something starts (the main
	-- chunk, or a callback handed to Connect and the like) down to fn; line is where that function makes
	-- the call to the next one. Each chain is {entry = how its first function starts, steps = {...}}, the
	-- shortest first. A function that nothing in the script calls ends a chain too (entry = nil).
	function A.CallChains(R, fn, limit)
		limit = limit or 20
		local callers = R.callersOf
		if not callers then
			callers = {}
			for _, c in ipairs(R.calls) do
				for _, t in ipairs(A.CallTargets(R, c) or {}) do
					if t ~= c.ctxFn then
						local list = callers[t]
						if not list then
							list = {}
							callers[t] = list
						end
						list[#list + 1] = c
					end
				end
			end
			R.callersOf = callers
		end

		local chains = {}
		local stack = {{fn = fn}} -- the chain so far, the function it ends in first
		local onPath = {[fn] = true}
		local function emit(entry)
			local steps = {}
			for i = #stack, 1, -1 do steps[#steps + 1] = {fn = stack[i].fn, line = stack[i].line} end
			chains[#chains + 1] = {entry = entry, steps = steps}
		end
		local function walk(f, depth)
			if #chains >= limit * 3 then return end
			local entry = (not f.parent and "script start") or (f.hintCall and A.FunctionName(R, f)) or nil
			local cs = callers[f]
			if entry then emit(entry) end
			if (not cs or depth >= 12) then
				if not entry then emit(nil) end
				return
			end
			local any = false
			for _, c in ipairs(cs) do
				local from = c.ctxFn
				if not onPath[from] then
					any = true
					onPath[from] = true
					stack[#stack + 1] = {fn = from, line = R.tl[c.s]}
					walk(from, depth + 1)
					stack[#stack] = nil
					onPath[from] = nil
				end
			end
			if not any and not entry then emit(nil) end -- only a loop of calls leads here
		end
		walk(fn, 0)
		table.sort(chains, function(a, b) return #a.steps < #b.steps end)
		for i = #chains, limit + 1, -1 do chains[i] = nil end
		return chains
	end

	-- The require(...) calls: {line, fn, path} with the path resolved the way a remote's is (path.root and
	-- path.steps are set when it points at something in the game).
	-- Whether a call is require(x) (the real one, not a local of that name).
	local function isRequire(R, c)
		return not c.method and c.fn.k == "Name" and R.tv[c.fn.s] == "require" and not R.symAt[c.fn.s] and c.args[1] ~= nil
	end

	function A.Requires(R)
		local out = {}
		for _, c in ipairs(R.calls) do
			if isRequire(R, c) then
				out[#out + 1] = {line = R.tl[c.s], fn = c.ctxFn, path = A.ResolvePath(R, c.args[1]), call = c}
			end
		end
		return out
	end

	----------------------------------------------------------------------------------------------
	-- Flowchart: a graph of basic blocks for one function. Nested functions are not entered; they
	-- hang off the statement that defines them (node.funcs) so the viewer can open them.
	----------------------------------------------------------------------------------------------

	local function trunc(s, max)
		if #s > max then return s:sub(1, max - 3) .. "..." end
		return s
	end

	-- Calls made directly by fn (not inside functions nested in it) that start between two tokens.
	local function callsBetween(R, fn, s, e)
		local sorted = R.callsByStart
		if not sorted then
			sorted = {}
			for i, c in ipairs(R.calls) do sorted[i] = c end
			table.sort(sorted, function(a, b) return a.s < b.s end)
			R.callsByStart = sorted
		end

		local lo, hi, first = 1, #sorted, #sorted + 1
		while lo <= hi do
			local mid = (lo + hi) // 2
			if sorted[mid].s >= s then
				first, hi = mid, mid - 1
			else
				lo = mid + 1
			end
		end

		local out = {}
		for i = first, #sorted do
			local c = sorted[i]
			if c.s > e then break end
			if c.ctxFn == fn and c.e <= e then out[#out + 1] = c end
		end
		return out
	end

	function A.BuildFlow(R, fn, opts)
		local maxNodes = opts and opts.maxNodes or 400
		local maxBlockLines = 6
		local nodes, edges = {}, {}
		local G = {nodes = nodes, edges = edges, fn = fn, R = R, mode = "flow"}
		local loops = {}
		local openBlock

		local function newNode(kind, label, line1, line2)
			local nd = {id = #nodes + 1, kind = kind, label = label, line1 = line1, line2 = line2 or line1, stmts = {}, funcs = {}, calls = {}}
			nodes[nd.id] = nd
			return nd
		end
		local function link(from, to, kind, label)
			edges[#edges + 1] = {from = from.id, to = to.id, kind = kind or "next", label = label}
		end
		local function connect(pend, to)
			for _, pe in ipairs(pend) do link(pe.node, to, pe.kind, pe.label) end
		end
		local function isOpen(pend)
			return openBlock and #pend == 1 and pend[1].node == openBlock and pend[1].kind == "next"
		end
		local function head(st)
			local text = A.LineText(R, st.line1)
			if st.line2 > st.line1 then text = text .. " ..." end
			return trunc(text, 60)
		end
		-- nd.calls: the functions of this script that the node's code calls (a button opens each one)
		local function addCalls(nd, s, e)
			for _, c in ipairs(callsBetween(R, fn, s, e)) do
				for _, target in ipairs(A.CallTargets(R, c) or {}) do
					if target ~= fn and #nd.calls < 8 and not table.find(nd.calls, target) then
						nd.calls[#nd.calls + 1] = target
					end
				end
			end
		end
		local function addStmt(nd, st)
			addCalls(nd, st.s, st.e)
			nd.stmts[#nd.stmts + 1] = st
			nd.line1 = nd.line1 or st.line1
			nd.line2 = st.line2
			nd.tint = nd.tint or st.kind
			for _, f in ipairs(st.funcs or {}) do nd.funcs[#nd.funcs + 1] = f end
		end
		local function condNode(kind, prefix, s, e, line1, line2)
			local nd = newNode(kind, prefix .. A.Text(R, s, e, 56), line1, line2)
			addCalls(nd, s, e)
			return nd
		end

		local visitBlock
		local function visit(st, pend)
			local k = st.k
			if k == "TypeStat" then
				return pend
			elseif k == "Local" or k == "Assign" or k == "Compound" or k == "CallStat" or k == "ExprStat" or k == "LocalFunction" or k == "FunctionStat" then
				local nd = openBlock
				if not isOpen(pend) then
					nd = newNode("block")
					connect(pend, nd)
					openBlock = nd
				end
				addStmt(nd, st)
				return {{node = nd, kind = "next"}}
			elseif k == "Do" then
				return visitBlock(st.body, pend)
			end

			openBlock = nil
			if k == "If" then
				local exits = {}
				local falsePend = pend
				for i, cl in ipairs(st.clauses) do
					local cond = condNode("cond", i == 1 and "if " or "elseif ", cl.cond.s, cl.cond.e, R.tl[cl.s], R.tel[cl.thenTok] or R.tl[cl.s])
					connect(falsePend, cond)
					for _, e in ipairs(visitBlock(cl.body, {{node = cond, kind = "true", label = "yes"}})) do exits[#exits + 1] = e end
					falsePend = {{node = cond, kind = "false", label = "no"}}
					openBlock = nil
				end
				if st.els then
					for _, e in ipairs(visitBlock(st.els, falsePend)) do exits[#exits + 1] = e end
				else
					for _, e in ipairs(falsePend) do exits[#exits + 1] = e end
				end
				openBlock = nil
				return exits
			elseif k == "While" or k == "NumFor" or k == "GenFor" then
				local loopHead = newNode("loop", trunc(A.Text(R, st.s, st.doTok - 1, 60), 60), R.tl[st.s], R.tel[st.doTok - 1])
				addCalls(loopHead, st.s, st.doTok - 1)
				connect(pend, loopHead)
				local ctx = {breaks = {}, continues = {}}
				loops[#loops + 1] = ctx
				local bodyExits = visitBlock(st.body, {{node = loopHead, kind = "true", label = "yes"}})
				loops[#loops] = nil
				for _, e in ipairs(bodyExits) do
					if e.node ~= loopHead then link(e.node, loopHead, "back", e.label) end
				end
				for _, c in ipairs(ctx.continues) do link(c, loopHead, "back", "continue") end
				openBlock = nil
				local exits = {}
				local forever = k == "While" and st.cond.k == "Bool" and R.tv[st.cond.s] == "true"
				if not forever then exits[1] = {node = loopHead, kind = "false", label = "done"} end
				for _, b in ipairs(ctx.breaks) do exits[#exits + 1] = b end
				return exits
			elseif k == "Repeat" then
				local ctx = {breaks = {}, continues = {}}
				loops[#loops + 1] = ctx
				local firstIdx = #nodes + 1
				local bodyExits = visitBlock(st.body, pend)
				loops[#loops] = nil
				local exits = {}
				if #bodyExits > 0 or #ctx.continues > 0 then
					local cond = condNode("loop", "until ", st.cond.s, st.cond.e, R.tl[st.untilTok], R.tel[st.cond.e])
					connect(bodyExits, cond)
					for _, c in ipairs(ctx.continues) do link(c, cond, "next", "continue") end
					local first = nodes[firstIdx]
					if first and first ~= cond then link(cond, first, "back", "no") end
					exits[1] = {node = cond, kind = "true", label = "yes"}
				end
				for _, b in ipairs(ctx.breaks) do exits[#exits + 1] = b end
				openBlock = nil
				return exits
			elseif k == "Return" then
				local nd = newNode("ret", trunc(A.Text(R, st.s, st.e, 60), 60), st.line1, st.line2)
				addCalls(nd, st.s, st.e)
				nd.tint = st.kind
				for _, f in ipairs(st.funcs or {}) do nd.funcs[#nd.funcs + 1] = f end
				connect(pend, nd)
				return {}
			elseif k == "Break" or k == "Continue" then
				local nd = newNode(k == "Break" and "break" or "continue", k == "Break" and "break" or "continue", st.line1, st.line2)
				connect(pend, nd)
				local ctx = loops[#loops]
				if ctx then
					local list = k == "Break" and ctx.breaks or ctx.continues
					list[#list + 1] = k == "Break" and {node = nd, kind = "break"} or nd
				end
				return {}
			end
			return pend
		end

		visitBlock = function(block, pend)
			for _, st in ipairs(block.body) do
				if #pend == 0 then break end
				if #nodes >= maxNodes then
					G.truncated = true
					local nd = newNode("block", "... graph truncated", st.line1, block.body[#block.body].line2)
					connect(pend, nd)
					return {}
				end
				pend = visit(st, pend)
			end
			return pend
		end

		local startLabel = fn.parent and A.Signature(R, fn) or "script (main chunk)"
		local start = newNode("start", trunc(startLabel, 60), fn.line1, fn.line1)
		visitBlock(fn.body, {{node = start, kind = "next"}})

		for _, nd in ipairs(nodes) do
			if nd.kind == "block" and #nd.stmts > 0 then
				local lines = {}
				for i, st in ipairs(nd.stmts) do
					if i > maxBlockLines then
						lines[#lines + 1] = "... +" .. (#nd.stmts - maxBlockLines) .. " more"
						break
					end
					lines[i] = head(st)
				end
				nd.label = table.concat(lines, "\n")
			end
			-- a plain box that calls into the script's own functions stands out, unless something else already tints it
			if nd.kind == "block" and #nd.calls > 0 and not nd.tint then nd.tint = "calls" end
		end
		return G
	end

	-- Node whose source lines contain a line (the tightest one), for syncing the editor cursor.
	function A.NodeAtLine(G, line)
		local best, span
		for _, nd in ipairs(G.nodes) do
			if nd.line1 and line >= nd.line1 and line <= nd.line2 then
				local s = nd.line2 - nd.line1
				if not best or s < span then best, span = nd, s end
			end
		end
		return best
	end

	----------------------------------------------------------------------------------------------
	-- Layout: layered. Ranks by longest path, long edges routed through dummy nodes, barycenter
	-- ordering, x placement by isotonic regression, then orthogonal edge routes. Loop (back) edges
	-- run down a lane left of everything and enter the loop head from above.
	----------------------------------------------------------------------------------------------

	local function estimate(nd)
		local lines, widest = 1, 0
		for line in (nd.label or ""):gmatch("[^\n]+") do
			widest = math.max(widest, #line)
		end
		for _ in (nd.label or ""):gmatch("\n") do lines += 1 end
		return math.clamp(widest * 7 + 20, 70, 340), lines * 15 + 12
	end

	local function simplify(pts)
		local res = {}
		for _, pt in ipairs(pts) do
			local last = res[#res]
			if not (last and last[1] == pt[1] and last[2] == pt[2]) then
				res[#res + 1] = pt
				local m = #res
				if m >= 3 then
					local a, b, c = res[m - 2], res[m - 1], res[m]
					if (a[1] == b[1] and b[1] == c[1]) or (a[2] == b[2] and b[2] == c[2]) then
						res[m - 1] = c
						res[m] = nil
					end
				end
			end
		end
		return res
	end

	function A.Layout(G, measure)
		measure = measure or estimate
		local nodes, edges = G.nodes, G.edges
		local count = #nodes
		local HGAP, VGAP, MARGIN, LANE = 26, 46, 24, 12

		for _, nd in ipairs(nodes) do
			nd.w, nd.h = measure(nd)
		end

		-- forward edges and back edges (builder-flagged loops, plus any cycle a DFS finds)
		local out = {}
		for i = 1, count do out[i] = {} end
		for _, e in ipairs(edges) do
			e.back = e.kind == "back" or e.from == e.to
			e.chain, e.pts = nil, nil
			if not e.back then table.insert(out[e.from], e) end
		end
		local color = {}
		for root = 1, count do
			if not color[root] then
				color[root] = 1
				local stack = {{root, 1}}
				while #stack > 0 do
					local top = stack[#stack]
					local o = out[top[1]]
					if top[2] > #o then
						color[top[1]] = 2
						stack[#stack] = nil
					else
						local e = o[top[2]]
						top[2] += 1
						if color[e.to] == 1 then
							e.back = true
						elseif not color[e.to] then
							color[e.to] = 1
							stack[#stack + 1] = {e.to, 1}
						end
					end
				end
			end
		end

		local fout, fin, indeg = {}, {}, {}
		for i = 1, count do fout[i], fin[i], indeg[i] = {}, {}, 0 end
		for _, e in ipairs(edges) do
			if not e.back then
				table.insert(fout[e.from], e)
				table.insert(fin[e.to], e)
				indeg[e.to] += 1
			end
		end

		local rank, queue, qi = {}, {}, 1
		for i = 1, count do
			if indeg[i] == 0 then
				queue[#queue + 1] = i
				rank[i] = 0
			end
		end
		while qi <= #queue do
			local u = queue[qi]
			qi += 1
			for _, e in ipairs(fout[u]) do
				rank[e.to] = math.max(rank[e.to] or 0, rank[u] + 1)
				indeg[e.to] -= 1
				if indeg[e.to] == 0 then queue[#queue + 1] = e.to end
			end
		end

		-- layers of items (real nodes and dummies for edges spanning several ranks)
		local layers, items, seq = {}, {}, 0
		for i = 1, count do
			local nd = nodes[i]
			local it = {node = nd, w = nd.w, h = nd.h, rank = rank[i], key = i}
			nd.item, nd.rank = it, rank[i]
			items[#items + 1] = it
			layers[rank[i] + 1] = layers[rank[i] + 1] or {}
			table.insert(layers[rank[i] + 1], it)
		end
		local up, down = {}, {}
		local function link(a, b)
			down[a] = down[a] or {}
			table.insert(down[a], b)
			up[b] = up[b] or {}
			table.insert(up[b], a)
		end
		for _, e in ipairs(edges) do
			if not e.back then
				local a, b = nodes[e.from].item, nodes[e.to].item
				local chain = {a}
				for r = a.rank + 1, b.rank - 1 do
					seq += 1
					local d = {dummy = true, w = 10, h = 0, rank = r, key = a.key + seq / 100000}
					table.insert(layers[r + 1], d)
					chain[#chain + 1] = d
				end
				chain[#chain + 1] = b
				for i = 1, #chain - 1 do link(chain[i], chain[i + 1]) end
				e.chain = chain
			end
		end

		local function byKey(x, y) return x.key < y.key end
		local function setPos(L)
			for i, it in ipairs(L) do it.pos = i end
		end
		for _, L in ipairs(layers) do
			table.sort(L, byKey)
			setPos(L)
		end
		local function sweep(L, nbrs)
			for _, it in ipairs(L) do
				local ns = nbrs[it]
				if ns and #ns > 0 then
					local sum = 0
					for _, o in ipairs(ns) do sum += o.pos end
					it.bary = sum / #ns
				else
					it.bary = it.pos
				end
			end
			table.sort(L, function(x, y)
				if x.bary ~= y.bary then return x.bary < y.bary end
				return x.pos < y.pos
			end)
			setPos(L)
		end
		for _ = 1, 4 do
			for r = 2, #layers do sweep(layers[r], up) end
			for r = #layers - 1, 1, -1 do sweep(layers[r], down) end
		end

		-- x placement: pull items toward their neighbours' average, never overlapping
		local function sep(a, b)
			local gap = (a.dummy or b.dummy) and HGAP * 0.5 or HGAP
			return (a.w + b.w) / 2 + gap
		end
		local function place(L, desired)
			local m = #L
			local o = {0}
			for i = 2, m do o[i] = o[i - 1] + sep(L[i - 1], L[i]) end
			local sums, cnts, starts, nb = {}, {}, {}, 0
			for i = 1, m do
				nb += 1
				sums[nb], cnts[nb], starts[nb] = desired[i] - o[i], 1, i
				while nb > 1 and sums[nb - 1] / cnts[nb - 1] > sums[nb] / cnts[nb] do
					sums[nb - 1] += sums[nb]
					cnts[nb - 1] += cnts[nb]
					nb -= 1
				end
			end
			for b = 1, nb do
				local mean = sums[b] / cnts[b]
				for i = starts[b], starts[b] + cnts[b] - 1 do L[i].x = mean + o[i] end
			end
		end
		local function average(list)
			local sum = 0
			for _, o in ipairs(list) do sum += o.x end
			return sum / #list
		end
		for _, L in ipairs(layers) do
			local d = {}
			for i = 1, #L do d[i] = 0 end
			place(L, d)
		end
		for _ = 1, 8 do
			for r = 2, #layers do
				local L, d = layers[r], {}
				for i, it in ipairs(L) do d[i] = up[it] and average(up[it]) or it.x end
				place(L, d)
			end
			for r = #layers - 1, 1, -1 do
				local L, d = layers[r], {}
				for i, it in ipairs(L) do d[i] = down[it] and average(down[it]) or it.x end
				place(L, d)
			end
		end

		-- loop (back) edges run down a lane on whichever side is nearer to them, innermost loop closest
		local rawLeft, rawRight = math.huge, -math.huge
		for _, it in ipairs(items) do
			rawLeft = math.min(rawLeft, it.x - it.w / 2)
			rawRight = math.max(rawRight, it.x + it.w / 2)
		end
		local backsL, backsR = {}, {}
		for _, e in ipairs(edges) do
			if e.back and e.from ~= e.to then
				local u, v = nodes[e.from].item, nodes[e.to].item
				e.side = (u.x + v.x) / 2 < (rawLeft + rawRight) / 2 and "L" or "R"
				table.insert(e.side == "L" and backsL or backsR, e)
			end
		end
		local function bySpan(a, b)
			local sa, sb = nodes[a.from].rank - nodes[a.to].rank, nodes[b.from].rank - nodes[b.to].rank
			if sa ~= sb then return sa < sb end
			return a.from < b.from
		end
		table.sort(backsL, bySpan)
		table.sort(backsR, bySpan)

		local shift = MARGIN + (#backsL + 1) * LANE + 8 - rawLeft
		for _, L in ipairs(layers) do
			for _, it in ipairs(L) do it.x += shift end
		end
		local graphRight = rawRight + shift

		-- y placement
		local layerTop, layerH = {}, {}
		local y = VGAP
		for r, L in ipairs(layers) do
			local h = 0
			for _, it in ipairs(L) do h = math.max(h, it.h) end
			layerH[r], layerTop[r] = h, y
			for _, it in ipairs(L) do
				if it.dummy then
					it.y = y + h / 2
				else
					it.node.x, it.node.y = it.x - it.w / 2, y + (h - it.h) / 2
					it.node.cx = it.x
				end
			end
			y += h + VGAP
		end
		local function channelBelow(r) return layerTop[r + 1] + layerH[r + 1] + VGAP / 2 end

		-- ports: spread edges along a node's bottom/top so they don't pile onto one point; loop edges
		-- take the end nearest their lane (outermost lane outermost)
		local backOut, backIn = {}, {}
		local function ends(map, id)
			map[id] = map[id] or {L = {}, R = {}}
			return map[id]
		end
		for i = #backsL, 1, -1 do
			local e = backsL[i]
			table.insert(ends(backOut, e.from).L, e)
			table.insert(ends(backIn, e.to).L, e)
		end
		for _, e in ipairs(backsR) do
			table.insert(ends(backOut, e.from).R, e)
			table.insert(ends(backIn, e.to).R, e)
		end
		for _, nd in ipairs(nodes) do
			local outs, ins = {}, {}
			for _, e in ipairs(fout[nd.id]) do outs[#outs + 1] = e end
			for _, e in ipairs(fin[nd.id]) do ins[#ins + 1] = e end
			table.sort(outs, function(a, b) return a.chain[2].x < b.chain[2].x end)
			table.sort(ins, function(a, b) return a.chain[#a.chain - 1].x < b.chain[#b.chain - 1].x end)
			local function spread(list, field, around)
				local all = {}
				for _, e in ipairs(around and around.L or {}) do all[#all + 1] = e end
				for _, e in ipairs(list) do all[#all + 1] = e end
				for _, e in ipairs(around and around.R or {}) do all[#all + 1] = e end
				local step = math.min(30, (nd.w - 20) / math.max(#all, 1))
				for k, e in ipairs(all) do e[field] = nd.cx + (k - (#all + 1) / 2) * step end
			end
			spread(outs, "px", backOut[nd.id])
			spread(ins, "qx", backIn[nd.id])
		end

		for _, e in ipairs(edges) do
			if not e.back then
				local ch, pts = e.chain, {}
				for i = 1, #ch - 1 do
					local a, b = ch[i], ch[i + 1]
					local ax = i == 1 and e.px or a.x
					local bx = i == #ch - 1 and e.qx or b.x
					local ay = a.dummy and a.y or a.node.y + a.node.h
					local by = b.dummy and b.y or b.node.y
					local chY = channelBelow(a.rank)
					pts[#pts + 1] = {ax, ay}
					pts[#pts + 1] = {ax, chY}
					pts[#pts + 1] = {bx, chY}
					pts[#pts + 1] = {bx, by}
				end
				e.pts = simplify(pts)
				e.lx, e.ly = e.pts[1][1] + 3, e.pts[1][2] + 1
			end
		end

		-- parallel loop edges leaving/entering the same rank get slightly different channel heights
		local belowUsed, aboveUsed = {}, {}
		local function routeBack(list, laneOf)
			for i, e in ipairs(list) do
				local u, v = nodes[e.from], nodes[e.to]
				local laneX = laneOf(i)
				local ku, kv = math.min(belowUsed[u.rank] or 0, 4), math.min(aboveUsed[v.rank] or 0, 4)
				belowUsed[u.rank] = (belowUsed[u.rank] or 0) + 1
				aboveUsed[v.rank] = (aboveUsed[v.rank] or 0) + 1
				local chBelow = channelBelow(u.rank) + ku * 4
				local chAbove = layerTop[v.rank + 1] - VGAP / 2 - kv * 4
				e.pts = simplify({{e.px, u.y + u.h}, {e.px, chBelow}, {laneX, chBelow}, {laneX, chAbove}, {e.qx, chAbove}, {e.qx, v.y}})
				e.lx, e.ly = e.px + 3, u.y + u.h + 1
			end
		end
		local laneLeft = MARGIN + #backsL * LANE
		local laneRightStart = graphRight + 14
		routeBack(backsL, function(i) return laneLeft - (i - 1) * LANE end)
		routeBack(backsR, function(i) return laneRightStart + (i - 1) * LANE end)

		local maxX = graphRight
		if #backsR > 0 then maxX = laneRightStart + (#backsR - 1) * LANE end
		G.w, G.h = maxX + MARGIN, y
		return G
	end

	----------------------------------------------------------------------------------------------
	-- Line diff (Myers). Returns {{op, text}} with op " " (same), "-" (only in a), "+" (only in b).
	----------------------------------------------------------------------------------------------

	function A.Diff(a, b)
		local n, m = #a, #b
		local lo = 0
		while lo < n and lo < m and a[lo + 1] == b[lo + 1] do lo += 1 end
		local hiA, hiB = n, m
		while hiA > lo and hiB > lo and a[hiA] == b[hiB] do
			hiA -= 1
			hiB -= 1
		end

		local ops = {}
		for i = 1, lo do ops[#ops + 1] = {" ", a[i]} end

		local N, M = hiA - lo, hiB - lo
		local mid = {}
		if N == 0 or M == 0 then
			for i = 1, N do mid[#mid + 1] = {"-", a[lo + i]} end
			for j = 1, M do mid[#mid + 1] = {"+", b[lo + j]} end
		else
			-- ponytail: gives up on the middle past 1000 edits (shown as all removed + all added)
			local maxD = math.min(N + M, 1000)
			local V, trace, doneD = {[1] = 0}, {}, nil
			for d = 0, maxD do
				trace[d] = table.clone(V)
				for k = -d, d, 2 do
					local x
					if k == -d or (k ~= d and V[k - 1] < V[k + 1]) then x = V[k + 1] else x = V[k - 1] + 1 end
					local y = x - k
					while x < N and y < M and a[lo + x + 1] == b[lo + y + 1] do
						x += 1
						y += 1
					end
					V[k] = x
					if x >= N and y >= M then
						doneD = d
						break
					end
				end
				if doneD then break end
			end
			if doneD then
				local rev = {}
				local x, y = N, M
				for d = doneD, 0, -1 do
					local Vd = trace[d]
					local k = x - y
					local prevK
					if k == -d or (k ~= d and Vd[k - 1] < Vd[k + 1]) then prevK = k + 1 else prevK = k - 1 end
					local prevX = Vd[prevK]
					local prevY = prevX - prevK
					while x > prevX and y > prevY do
						rev[#rev + 1] = {" ", a[lo + x]}
						x -= 1
						y -= 1
					end
					if d > 0 then
						if x == prevX then rev[#rev + 1] = {"+", b[lo + y]} else rev[#rev + 1] = {"-", a[lo + x]} end
					end
					x, y = prevX, prevY
				end
				for i = #rev, 1, -1 do mid[#mid + 1] = rev[i] end
			else
				for i = 1, N do mid[#mid + 1] = {"-", a[lo + i]} end
				for j = 1, M do mid[#mid + 1] = {"+", b[lo + j]} end
			end
		end
		for _, op in ipairs(mid) do ops[#ops + 1] = op end
		for i = hiA + 1, n do ops[#ops + 1] = {" ", a[i]} end
		return ops
	end

	local function splitLines(s)
		local t = {}
		for line in (s .. "\n"):gmatch("(.-)\r?\n") do t[#t + 1] = line end
		if t[#t] == "" then t[#t] = nil end
		return t
	end

	-- The text's lines with every local renamed after where it first shows on its line (L1, L2, ...), so
	-- that two decompiles of the same code agree on them whatever numbers their variables got. The text is
	-- compared as it is when it does not parse.
	local function comparable(text, count)
		local ok, R = pcall(A.Analyze, text)
		if ok and R then
			local names, line, seen, n = {}, 0, {}, 0
			for i = 1, R.n do
				local sym = R.tt[i] == "name" and R.symAt[i]
				if sym and sym.decl then
					if R.tl[i] ~= line then line, seen, n = R.tl[i], {}, 0 end
					if not seen[sym] then
						n += 1
						seen[sym] = "L" .. n
					end
					names[i] = seen[sym]
				end
			end
			local lines = splitLines(splice(R, names))
			if #lines == count then return lines end
		end
		return splitLines(text)
	end

	-- Unified diff text with unchanged runs collapsed to context lines. kinds[i] is "add", "del",
	-- "same" or "hunk" for line i of the text. With ignoreLocals the lines are matched up by what they
	-- say apart from the names of local variables (the lines shown are the real ones).
	function A.DiffText(aText, bText, context, ignoreLocals)
		context = context or 3
		local aLines, bLines = splitLines(aText), splitLines(bText)
		local ops
		if ignoreLocals then
			ops = A.Diff(comparable(aText, #aLines), comparable(bText, #bLines))
			local i, j = 0, 0
			for _, op in ipairs(ops) do
				if op[1] == " " then
					i, j = i + 1, j + 1
					op[2] = bLines[j]
				elseif op[1] == "-" then
					i += 1
					op[2] = aLines[i]
				else
					j += 1
					op[2] = bLines[j]
				end
			end
		else
			ops = A.Diff(aLines, bLines)
		end
		local lines, kinds = {}, {}
		local added, removed = 0, 0
		local i = 1
		while i <= #ops do
			local op = ops[i]
			if op[1] == " " then
				local j = i
				while j <= #ops and ops[j][1] == " " do j += 1 end
				local run = j - i
				local first = i == 1
				local last = j > #ops
				local keepHead = first and 0 or context
				local keepTail = last and 0 or context
				if run > keepHead + keepTail + 1 then
					for x = i, i + keepHead - 1 do
						lines[#lines + 1], kinds[#lines + 1] = "  " .. ops[x][2], "same"
					end
					lines[#lines + 1], kinds[#lines + 1] = "@@ " .. (run - keepHead - keepTail) .. " unchanged lines @@", "hunk"
					for x = j - keepTail, j - 1 do
						lines[#lines + 1], kinds[#lines + 1] = "  " .. ops[x][2], "same"
					end
				else
					for x = i, j - 1 do
						lines[#lines + 1], kinds[#lines + 1] = "  " .. ops[x][2], "same"
					end
				end
				i = j
			else
				if op[1] == "+" then added += 1 else removed += 1 end
				lines[#lines + 1], kinds[#lines + 1] = op[1] .. " " .. op[2], op[1] == "+" and "add" or "del"
				i += 1
			end
		end
		return table.concat(lines, "\n"), kinds, {added = added, removed = removed}
	end

	----------------------------------------------------------------------------------------------
	-- Anchors: finding a line again in a newer decompile of the same script, so that notes,
	-- bookmarks and renames can follow it
	----------------------------------------------------------------------------------------------

	-- A line as an anchor sees it: without its indentation, the viewer's notes and the names a decompiler
	-- makes up, which change from one decompile to the next.
	function A.LineKey(text)
		text = text:gsub("%s%-%-%s>>%s.*$", "")
		text = text:gsub("[%a_][%w_]*", function(w) return A.LooksGenerated(w) and "_" or w end)
		return (text:gsub("%s+", " "):match("^%s*(.-)%s*$"))
	end

	-- What identifies line n of lines: its key and those of the lines around it.
	function A.Anchor(lines, n)
		return {line = n, key = A.LineKey(lines[n] or ""), prev = A.LineKey(lines[n - 1] or ""), next = A.LineKey(lines[n + 1] or "")}
	end

	-- Where each anchor's code is in lines, as a list in the order of the anchors (nil where it is gone).
	-- A line that shows up once is taken. One that shows up several times goes to the copy whose
	-- neighbours match, then to the nearest (at most 25 lines away when the neighbours do not help).
	function A.Reanchor(lines, anchors)
		local keys, byKey = {}, {}
		for i = 1, #lines do
			local k = A.LineKey(lines[i])
			keys[i] = k
			if k ~= "" then
				local list = byKey[k]
				if not list then
					list = {}
					byKey[k] = list
				end
				list[#list + 1] = i
			end
		end

		local out = {}
		for i, a in ipairs(anchors) do
			local list = a.key ~= "" and byKey[a.key]
			if list then
				local best, bestScore, bestDist
				for _, j in ipairs(list) do
					local score = (keys[j - 1] == a.prev and 1 or 0) + (keys[j + 1] == a.next and 1 or 0)
					local dist = math.abs(j - a.line)
					if not best or score > bestScore or (score == bestScore and dist < bestDist) then
						best, bestScore, bestDist = j, score, dist
					end
				end
				if #list == 1 or bestScore > 0 or bestDist <= 25 then out[i] = best end
			end
		end
		return out
	end

	----------------------------------------------------------------------------------------------
	-- Searching a text (the viewer searches every script's decompile with this)
	----------------------------------------------------------------------------------------------

	-- Finds query in a text: mode "text" (plain), "word" (a whole identifier) or "pattern" (a Lua pattern,
	-- case-sensitive). Plain and word searches ignore case unless matchCase. Returns up to max matches as
	-- {line, col (0-based), len, text (the line, trimmed and cut)}, or nil and why the query is no good.
	function A.SearchText(text, query, mode, matchCase, max)
		if query == "" then return {} end
		max = max or 100
		local hay, pat, plain = text, query, true
		if mode == "pattern" then
			if not pcall(string.find, "", query) then return nil, "That is not a valid Lua pattern" end
			plain = false
		else
			if not matchCase then
				hay, pat = text:lower(), query:lower()
			end
			if mode == "word" then
				pat, plain = "%f[%w_]" .. pat:gsub("%p", "%%%0") .. "%f[^%w_]", false
			end
		end

		local out = {}
		local init, line, lineStart = 1, 1, 1
		while #out < max do
			local s, e = hay:find(pat, init, plain)
			if not s then break end
			-- the line the match starts on, counted on from the last one found
			while true do
				local nl = text:find("\n", lineStart, true)
				if not nl or nl >= s then break end
				line += 1
				lineStart = nl + 1
			end
			local stop = text:find("\n", s, true)
			local shown = text:sub(lineStart, (stop or #text + 1) - 1):gsub("\r$", ""):match("^%s*(.-)%s*$")
			if #shown > 90 then shown = shown:sub(1, 87) .. "..." end
			out[#out + 1] = {line = line, col = s - lineStart, len = math.max(e - s + 1, 1), text = shown}
			init = math.max(e, s) + 1
		end
		return out
	end

	-- Like SearchText, over the tokens of a parsed script. mode "ident" finds a name (never inside a string
	-- or a comment), "string" a string literal with the query in it, "call" a call of a function or method:
	-- "FireServer", or "FireServer(Buy)" for the calls with Buy somewhere in their arguments. Case is ignored
	-- unless matchCase. Same result shape as SearchText; nil and why when the query is no good.
	function A.SearchTokens(R, query, mode, matchCase, max)
		if query == "" then return {} end
		max = max or 100
		local function norm(s) return matchCase and s or s:lower() end
		local out = {}
		local function add(ti)
			local line = R.tl[ti]
			local shown = A.LineText(R, line)
			if #shown > 90 then shown = shown:sub(1, 87) .. "..." end
			out[#out + 1] = {line = line, col = R.tp[ti] - A.LineStart(R, line), len = math.max(R.te[ti] - R.tp[ti] + 1, 1), text = shown}
		end

		if mode == "ident" then
			local want = norm(query)
			for i = 1, R.n do
				if #out >= max then break end
				if R.tt[i] == "name" and norm(R.tv[i]) == want then add(i) end
			end
		elseif mode == "string" then
			local want = norm(query)
			for i = 1, R.n do
				if #out >= max then break end
				if (R.tt[i] == "str" or R.tt[i] == "istr") and norm(A.StringValue(R, i)):find(want, 1, true) then add(i) end
			end
		elseif mode == "call" then
			local head, argText = query:match("^%s*([^%(]-)%s*%((.-)%)?%s*$")
			if not head then head, argText = query, "" end
			local name = head:match("([%w_]+)%s*$")
			if not name then return nil, "Write the name of a function, or name(text in its arguments)" end
			local wantName, wantArgs = norm(name), norm(argText)
			local hits = {}
			for _, c in ipairs(R.calls) do
				local ti = c.method or (c.fn.k == "Index" and c.fn.name) or (c.fn.k == "Name" and c.fn.s)
				if ti and norm(R.tv[ti]) == wantName then
					local a1, an = c.args[1], c.args[#c.args]
					if wantArgs == "" or (a1 and norm(A.Text(R, a1.s, an.e)):find(wantArgs, 1, true)) then hits[#hits + 1] = ti end
				end
			end
			table.sort(hits)
			for _, ti in ipairs(hits) do
				if #out >= max then break end
				add(ti)
			end
		else
			return nil, "Unknown way to search"
		end
		return out
	end

	----------------------------------------------------------------------------------------------
	-- The whole game: what one parse says about a script (kept instead of the parse), which scripts
	-- changed between two reads
	----------------------------------------------------------------------------------------------

	-- The require(...) call an expression stands for: the call itself, or a local that was set to one.
	local function requireCall(R, e)
		if e and e.k == "Paren" then e = e.inner end
		if e and e.k == "Name" then
			local sym = R.symAt[e.s]
			e = sym and sym.init -- ponytail: the declaring assignment only, like ResolvePath
		end
		if e and e.k == "Call" and isRequire(R, e) then return e end
		return nil
	end

	-- When a member name token (the "fn" of M.fn or M:fn()) belongs to a module that was required into M:
	-- {member, path (where require points), call}. nil otherwise.
	function A.ModuleMember(R, ti)
		local node = R.members[ti]
		if not node then return nil end
		local call = requireCall(R, node.k == "Index" and node.obj or node.fn)
		if not call then return nil end
		return {member = R.tv[ti], path = A.ResolvePath(R, call.args[1]), call = call}
	end

	local suspicious = {}
	for w in ("kick ban banned detect detected detection cheat cheater cheating exploit exploiter exploiting anticheat hack hacker"):gmatch("%a+") do
		suspicious[w] = true
	end

	local function countPlain(text, needle)
		local n, at = 0, 1
		while true do
			local s, e = text:find(needle, at, true)
			if not s then return n end
			n, at = n + 1, e + 1
		end
	end

	-- One parse boiled down to what pages about the whole game need, so the parse (big) can be dropped:
	-- lines, size, requires {line, path}, remotes (as Remotes, without the parse), named functions
	-- {name, short, line, params}, uses of required modules {req (index into requires), member, line, call,
	-- write}, and signs of what the script does (sig) with obf, how many signs of obfuscation it shows.
	function A.Digest(R)
		local d = {lines = #R.nl + 1, size = #R.src, requires = {}, remotes = {}, funcs = {}, uses = {}}

		local reqOf = {}
		for _, r in ipairs(A.Requires(R)) do
			if #d.requires >= 200 then break end
			d.requires[#d.requires + 1] = {line = r.line, path = r.path}
			reqOf[r.call] = #d.requires
		end

		local counts = {}
		for _, r in ipairs(A.Remotes(R)) do
			counts[r.kind] = (counts[r.kind] or 0) + 1
			if #d.remotes < 300 then
				d.remotes[#d.remotes + 1] = {kind = r.kind, method = r.method, line = r.line, path = r.path, args = r.args, argCount = r.argCount, fname = r.fn and A.FunctionName(R, r.fn) or nil}
			end
		end

		for _, f in ipairs(R.functions) do
			local short = A.ShortName(f)
			if f.parent and short and not A.LooksGenerated(short) and #d.funcs < 600 then
				d.funcs[#d.funcs + 1] = {name = f.name, short = short, line = f.line1, params = A.ParamCount(f)}
			end
		end

		local toks = {}
		for ti in pairs(R.members) do toks[#toks + 1] = ti end
		table.sort(toks)
		for _, ti in ipairs(toks) do
			if #d.uses >= 3000 then break end
			local node = R.members[ti]
			local call = requireCall(R, node.k == "Index" and node.obj or node.fn)
			local k = call and reqOf[call]
			if k then
				d.uses[#d.uses + 1] = {req = k, member = R.tv[ti], line = R.tl[ti], call = node.k == "Call" or (R.tt[ti + 1] == "op" and R.tv[ti + 1] == "("), write = R.writes[ti] == true}
			end
		end

		-- signs, counted in the text
		local src = R.src
		local longest, prev = 0, 0
		for _, pos in ipairs(R.nl) do
			longest = math.max(longest, pos - prev - 1)
			prev = pos
		end
		longest = math.max(longest, #src - prev)
		local words = 0
		for w in (src:gsub("(%l)(%u)", "%1 %2")):lower():gmatch("%a+") do
			if suspicious[w] then words += 1 end
		end
		local sig = {
			functions = #R.functions - 1,
			fire = counts.remote or 0, listen = counts.listen or 0, http = counts.http or 0,
			loadstring = countPlain(src, "loadstring"), fenv = countPlain(src, "getfenv") + countPlain(src, "setfenv"),
			debug = countPlain(src, "debug."), words = words, longest = longest,
			escapes = select(2, src:gsub("\\%d%d%d", "")), strchar = countPlain(src, "string.char"), bit = countPlain(src, "bit32."),
		}
		-- ponytail: a few signs in the text; token statistics (one huge table of strings, a numbered state machine) if it misses
		local obf = 0
		if sig.longest > 1500 then obf += 1 end
		if sig.escapes > 40 then obf += 1 end
		if sig.strchar > 15 then obf += 1 end
		if sig.bit > 30 then obf += 1 end
		sig.obf = obf
		d.sig = sig
		return d
	end

	-- {path, hash} items as a table key -> hash, and the key of each item. Two scripts that share a path get
	-- "path #hash" so they stay apart whatever order they are listed in.
	function A.IndexMap(items)
		local count = {}
		for _, it in ipairs(items) do count[it.path] = (count[it.path] or 0) + 1 end
		local map, keys = {}, {}
		for i, it in ipairs(items) do
			local key = count[it.path] > 1 and (it.path .. " #" .. it.hash:sub(1, 8)) or it.path
			map[key], keys[i] = it.hash, key
		end
		return map, keys
	end

	-- What differs between two IndexMaps: keys that are new, gone, or have another hash (all sorted).
	function A.ChangeSet(old, new)
		local out = {added = {}, removed = {}, changed = {}}
		for key, hash in pairs(new) do
			local was = old[key]
			if was == nil then
				out.added[#out.added + 1] = key
			elseif was ~= hash then
				out.changed[#out.changed + 1] = key
			end
		end
		for key in pairs(old) do
			if new[key] == nil then out.removed[#out.removed + 1] = key end
		end
		table.sort(out.added)
		table.sort(out.removed)
		table.sort(out.changed)
		return out
	end

	----------------------------------------------------------------------------------------------
	-- Roblox classes: what an expression is, and what the API says about a member. classes is the
	-- API's class table (name -> {Superclass, Properties, Functions, Events, Callbacks}).
	----------------------------------------------------------------------------------------------

	local memberLists = {{"Properties", "property"}, {"Functions", "function"}, {"Events", "event"}, {"Callbacks", "callback"}}

	-- A member of a class or the classes it inherits from: {kind, member, class (where it is declared)}.
	function A.FindMember(classes, className, name)
		local cls = classes[className]
		while cls do
			for _, kind in ipairs(memberLists) do
				for _, m in ipairs(cls[kind[1]] or {}) do
					if m.Name == name then return {kind = kind[2], member = m, class = cls.Name} end
				end
			end
			cls = cls.Superclass
		end
		return nil
	end

	-- The class of what an expression gives, as far as the code says: game, workspace, GetService("X"),
	-- Instance.new("X"), a property or method of a known class that gives an object, a child named
	-- like a class. nil when unknown.
	function A.ClassOf(R, e, classes, depth)
		depth = depth or 0
		if not e or depth > 6 then return nil end
		local k = e.k
		if k == "Paren" or k == "Cast" then return A.ClassOf(R, e.inner, classes, depth + 1) end

		if k == "Name" then
			local sym = R.symAt[e.s]
			if sym then return sym.init and sym.init ~= e and A.ClassOf(R, sym.init, classes, depth + 1) or nil end
			local name = R.tv[e.s]
			if name == "game" then return "DataModel" end
			if name == "workspace" then return "Workspace" end
			return nil
		end

		if k == "Index" then
			local base = A.ClassOf(R, e.obj, classes, depth + 1)
			local key = e.name and R.tv[e.name] or (e.key and e.key.k == "String" and A.StringValue(R, e.key.s))
			if not (base and key) then return nil end
			local found = A.FindMember(classes, base, key)
			if found then
				local vt = found.kind == "property" and found.member.ValueType
				return (vt and vt.Category == "Class" and classes[vt.Name]) and vt.Name or nil
			end
			return classes[key] and key or nil -- a child (a service of game, say) named like its class
		end

		if k == "Call" then
			local arg = e.args[1]
			local str = arg and arg.k == "String" and A.StringValue(R, arg.s)
			local m = e.method and R.tv[e.method]
			if m then
				if str and classes[str] and (m == "GetService" or m == "WaitForChild" or m == "FindFirstChild" or m:match("^FindFirst%a*Class") or m:match("^FindFirst%a*WhichIsA")) then
					return str
				end
				if m == "Clone" then return A.ClassOf(R, e.fn, classes, depth + 1) end
				local base = A.ClassOf(R, e.fn, classes, depth + 1)
				local found = base and A.FindMember(classes, base, m)
				local ret = found and found.kind == "function" and found.member.ReturnType
				return (ret and classes[ret]) and ret or nil
			end
			local f = e.fn
			if f.k == "Index" and f.name and R.tv[f.name] == "new" and f.obj.k == "Name" and R.tv[f.obj.s] == "Instance" and str and classes[str] then
				return str
			end
		end
		return nil
	end

	-- What the API says about the field or method a name token is (the "b" of a.b or a:b): {class (of
	-- the object), kind, member, declared (the class that declares it)}, or nil when the object's class is
	-- not known or has no such member.
	function A.MemberAt(R, ti, classes)
		local node = R.members[ti]
		if not node then return nil end
		local class = A.ClassOf(R, node.k == "Index" and node.obj or node.fn, classes)
		local found = class and A.FindMember(classes, class, R.tv[ti])
		if not found then return nil end
		return {class = class, kind = found.kind, member = found.member, declared = found.class}
	end

	return A
end

return {InitDeps = initDeps, InitAfterMain = initAfterMain, Main = main}
