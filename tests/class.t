
local Class = {}
Class.class = {}
Class.class.__index = Class.class
Class.defined = {}

Class.interface = {}
Class.interface.__index = Class.interface

Class.parentclasstable = {}
function Class.issubclass(c,t)
    if c == t then 
        return true 
    end
    local parent = Class.parentclasstable[c]
    if parent and Class.issubclass(parent,t) then
        return true
    end

    return false
end

function Class.castmethod(ctx,tree,from,to,exp)
    if from:ispointer() and to:ispointer() then
        if Class.issubclass(from.type,to.type) then
            return true, `exp:as(to)
        end
        local builder = Class.defined[from.type]
        assert(builder)
        local ifacename = builder.interfacetable[to.type]
        if ifacename then
            return true, `&terralib.select(exp,ifacename)
        end
    end
    return false
end

function Class.define(name,parentclass)
    local c = setmetatable({},Class.class)
    c.ttype = terralib.types.newstruct(name)
    c.ttype.methods.__cast = Class.castmethod
    Class.defined[c.ttype] = c
    c.members = terralib.newlist()
    Class.parentclasstable[c.ttype] = parentclass
    c.parentbuilder = Class.defined[parentclass]
    c.name = name
    c.interfaces = terralib.newlist()
    c.ttype:addlayoutfunction(function(self,ctx)
        local function addmembers(cls)
            local parent = Class.parentclasstable[cls]
            if parent then
                addmembers(parent)
            end
            local builder = Class.defined[cls]
            for i,m in ipairs(builder.members) do
                self:addentry(m.name,m.type)
            end
        end

        c:createvtable(ctx)
        self:addentry("__vtable",&c.vtabletype)
        addmembers(self)

        local initinterfaces = c:createinterfaces(ctx)
        local vtable = c.vtablevar
        terra self:init()
            self.__vtable = &vtable
            initinterfaces(self)
        end

    end)
    
    return c
end

function Class.class:member(name,typ)
    self.members:insert( { name = name, type = typ })
    return self
end

function Class.class:createvtable(ctx)
    if self.vtableentries ~= nil then
        return
    end

    print("CREATE VTABLE: ",self.name)
    self.vtableentries = terralib.newlist{}
    self.vtablemap = {}

    if self.parentbuilder then
        self.parentbuilder:createvtable(ctx)
        for _,i in ipairs(self.parentbuilder.vtableentries) do
            local e = {name = i.name, value = i.value}
            self.vtableentries:insert(e)
            self.vtablemap[i.name] = e
        end
    end
    for name,method in pairs(self.ttype.methods) do
        if terralib.isfunction(method) then
            if self.vtablemap[name] then
                --TODO: we should check that the types match...
                --but i am lazy
                self.vtablemap[name].value = method
            else
                local e = {name = name, value = method}
                self.vtableentries:insert(e)
                self.vtablemap[name] = e
            end
        end
    end
    local vtabletype = terralib.types.newstruct(self.name.."_vtable")
    local inits = terralib.newlist()
    for _,e in ipairs(self.vtableentries) do
        assert(terralib.isfunction(e.value))
        assert(#e.value:getvariants() == 1)
        local variant = e.value:getvariants()[1]
        local success,typ = variant:peektype(ctx)
        assert(success)
        print(e.name,"->",&typ)
        vtabletype:addentry(e.name,&typ)
        inits:insert(`e.value)
        self.ttype.methods[e.name] = macro(function(ctx,tree,self,...)
            local arguments = {...}
            --this is wrong: it evaluates self twice, we need a new expression:  let x = <exp> in <exp> end 
            --to easily handle this case.
            --another way to do this would be to generate a stub function forward the arguments
            return `(terralib.select(self.__vtable,e.name))(&self,arguments)
        end)
    end

    local var vtable : vtabletype = {inits}
    self.vtabletype = vtabletype
    self.vtablevar = vtable
end

function Class.class:createinterfaces(ctx)
    local interfaceinits = terralib.newlist()
    self.interfacetable = {}
    local function addinterfaces(cls)
        if cls.parentbuilder then
            addinterfaces(cls.parentbuilder)
        end
        for i,interface in ipairs(cls.interfaces) do
            local iname = "__interface"..i
            self.interfacetable[iname] = interface:type()
            self.ttype:addentry(iname,interface:type())
            local methods = terralib.newlist()
            for _,m in ipairs(interface.methods) do
                local methodentry = self.vtablemap[m.name]
                assert(methodentry)
                assert(methodentry.name == m.name)
                --TODO: check that the types match...
                local methodliteral = m.value:getvariants()[1]
                methods:insert(`methodliteral:as(m.type))
            end
            local var interfacevtable : interface.vtabletype = {methods}
            interfaceinits:insert(interfacevtable)
        end
    end
    addinterfaces(self)
    return macro(function(ctx,tree,self)
        local stmts = terralib.newlist()
        for i,vtable in ipairs(interfaceinits) do
            local name = "__interface"..i
            stmts:insert(quote
                terralib.select(self,name) = &vtable
            end)
        end
        return stmts
    end)
end

function Class.class:implements(interface)
    self.interfaces:insert(interface)

end

function Class.class:type()
    return self.ttype
end

function Class.defineinterface(name)
    local self = setmetatable({},Class.interface)
    self.methods = terralib.newlist()
    self.vtabletype = terralib.newstruct(name.."_vtable")
    self.interfacetype = terralib.newstruct(name)
    self.interfacetype:addentry("__vtable",&self.vtabletype)
    return self
end

function Class.interface:method(name,typ)
    assert(typ:ispointer() and typ.type:isfunction())
    local returns = typ.type.returns
    local parameters = terralib.newlist({&int8})
    for _,e in ipairs(typ.type.parameters) do
        parameters:insert(e)
    end
    local interfacetype = parameters -> returns
    self.methods:insert({name = name, type = interfacetype})
    self.vtabletype:addentry(name,interfacetype)
    self.interfacetype.methods[name] = macro(function(ctx,tree,self,...)
        local arguments = terralib.newlist{...}
        return `(terralib.select(self.__vtable,name))((&self):as(&uint8) - self.__vtable.offset,arguments)
    end)
    return self
end

function Class.interface:type()
    return self.interfacetype
end

A = Class.define("A")
    :member("a",int)
    :type()
    
terra A:double() : int
    return self.a*2
end
    
B = Class.define("B",A)
    :member("b",int)
    :type()
    
terra B:combine(a : int) : int
    return self.b + self.a + a
end
    
C = Class.define("C",B)
    :member("c",double)
    :type()
    
terra C:combine(a : int) : int
    return self.c + self.a + self.b + a
end

terra C:double() : double
    return self.a * 4
end

terra doubleAnA(a : &A)
    return a:double()
end

terra combineAB(b : &B)
    return b:combine(3)
end

terra returnA(a : A)
    return a
end

terra foobar()

    var a = A {nil, 1 }
    var b = B {nil, 1, 2 }
    var c = C {nil, 1, 2, 3.5 }
    a:init()
    b:init()
    c:init()
    return doubleAnA(&a) + doubleAnA(&b) + doubleAnA(&c) + combineAB(&b) + combineAB(&c)
end
local test = require("test")
test.eq(23,foobar())

