Class Utils.JSON2Class Extends %RegisteredObject
{

/// Genera clases .cls directamente en disco.
/// Devuelve el número de ficheros generados.
ClassMethod Convert(json As %String, basePackage As %String = "App.Model", rootClassName As %String = "Root", outDir As %String = "/shared/generated") As %String
{
    // Normaliza a UTF-8 (para que Python no sufra con encodings)
    set jsonUtf8 = $ZCONVERT(json,"O","UTF8")

    // Base64 (ASCII) para cruzar a Python de forma estable (sin UnicodeDecodeError)
    // Si en tu versión no existe %SYSTEM.Encryption.Base64Encode, dímelo y lo adapto.
    set b64 = ##class(%SYSTEM.Encryption).Base64Encode(jsonUtf8)

    quit ..ConvertB64ToFiles(b64, basePackage, rootClassName, outDir)
}

/// Implementación en Embedded Python: recibe Base64 y escribe .cls en outDir.
/// Devuelve el número de ficheros escritos.
ClassMethod ConvertB64ToFiles(b64 As %String, basePackage As %String = "App.Model", rootClassName As %String = "Root", outDir As %String = "/shared/generated") As %String [ Language = python ]
{
    import iris
    import json as _json
    import re
    import base64
    import os
    from decimal import Decimal

    # Args pequeños ASCII / simples
    b64 = str(b64)
    basePackage = str(basePackage)
    rootClassName = str(rootClassName)
    outDir = str(outDir)

    # Decode Base64 -> bytes -> UTF-8 string
    raw_bytes = base64.b64decode(b64.encode("ascii", "strict"))
    json_text = raw_bytes.decode("utf-8", "strict")

    def sanitize_identifier(name: str) -> str:
        """
        Genera un identificador válido para NOMBRE DE PROPIEDAD:
        - Solo [0-9a-zA-Z]
        - Sin underscores
        - Si empieza por dígito, prefija 'P'
        """
        if name is None:
            return "Prop"
        s = str(name).strip()
        if s == "":
            return "Prop"

        # elimina cualquier carácter que no sea alfanumérico (incluye '_' y '-')
        s = re.sub(r'[^0-9a-zA-Z]', '', s)

        if s == "":
            return "Prop"

        # no puede empezar por número
        if re.match(r'^[0-9]', s):
            s = "P" + s

        return s

    def to_class_name(name: str) -> str:
        """
        Genera un nombre de CLASE PascalCase:
        - Usa el nombre original como fuente (para preservar 'palabras')
        - El resultado final no contiene underscores
        """
        if name is None:
            return "Root"

        raw = str(name).strip()
        if raw == "":
            return "Root"

        # separa en "palabras" por cualquier no-alfanumérico (incluye '_' '-')
        parts = re.split(r'[^0-9a-zA-Z]+', raw)
        parts = [p for p in parts if p]

        if not parts:
            return "Root"

        # PascalCase
        cls = "".join(p[0].upper() + p[1:] if len(p) > 1 else p.upper() for p in parts)

        # si empieza por dígito, prefija 'C' (más seguro para clases)
        if re.match(r'^[0-9]', cls):
            cls = "C" + cls

        return cls

    def is_date_only(s: str) -> bool:
        return bool(re.match(r'^\d{4}-\d{2}-\d{2}$', s))

    def is_timestamp(s: str) -> bool:
        # ISO 8601 con hora (T o espacio), opcional fracción y zona
        return bool(re.match(
            r'^\d{4}-\d{2}-\d{2}([T\s]\d{2}:\d{2}(:\d{2})?(\.\d+)?(Z|[+\-]\d{2}:\d{2})?)$',
            s
        ))

    def scalar_type(v):
        if v is None:
            return None
        if isinstance(v, bool):
            return "%Boolean"
        if isinstance(v, int) and not isinstance(v, bool):
            return "%Integer"
        if isinstance(v, float):
            return "%Numeric"
        if isinstance(v, (Decimal,)):
            return "%Numeric"
        if isinstance(v, str):
            if is_date_only(v):
                return "%Date"
            if is_timestamp(v):
                return "%TimeStamp"
            return "%String"
        return "%String"

    def merge_types(t1, t2):
        if t1 is None:
            return t2
        if t2 is None:
            return t1
        if t1 == t2:
            return t1
        numeric = {"%Integer", "%Numeric"}
        if t1 in numeric and t2 in numeric:
            return "%Numeric"
        if (t1 == "%TimeStamp" and t2 == "%String") or (t2 == "%TimeStamp" and t1 == "%String"):
            return "%String"
        return "%String"

    def is_sql_reserved(word: str) -> bool:
        # $SYSTEM.SQL.IsReservedWord("...") (case-insensitive)
        try:
            return bool(iris.cls("%SYSTEM.SQL").IsReservedWord(str(word)))
        except Exception:
            return False

    # classes[fullName] = { kind, props: {propName: meta}, order: [propName] }
    classes = {}

    def ensure_class(full_name, kind):
        if full_name not in classes:
            classes[full_name] = {"kind": kind, "props": {}, "order": []}

    def merge_type_specs(a, b):
        if a == b:
            return a
        if isinstance(a, tuple) and isinstance(b, tuple):
            ka, va = a
            kb, vb = b
            if ka == kb == "scalar":
                return ("scalar", merge_types(va, vb))
            if ka == kb == "list":
                return ("list", merge_types(va, vb))
            if ka == kb == "serial" and va == vb:
                return a
            if ka == kb == "list_serial" and va == vb:
                return a
        return ("scalar", "%String")

    def set_prop(class_full, prop_name, json_name, type_spec):
        c = classes[class_full]
        if prop_name not in c["props"]:
            c["props"][prop_name] = {"json_name": json_name, "type_spec": type_spec}
            c["order"].append(prop_name)
        else:
            old = c["props"][prop_name]["type_spec"]
            c["props"][prop_name]["type_spec"] = merge_type_specs(old, type_spec)

    def unique_prop_name(class_full, desired_prop, desired_json_name):
        """
        Si desired_prop ya existe pero mapea a otro json_name, genera un nombre alternativo:
        - primero intenta PropJSON
        - luego PropJSON2, PropJSON3...
        """
        c = classes[class_full]
        if desired_prop not in c["props"]:
            return desired_prop

        existing_json = c["props"][desired_prop]["json_name"]
        if str(existing_json) == str(desired_json_name):
            return desired_prop

        base = desired_prop
        candidate = base + "JSON"
        if candidate not in c["props"]:
            return candidate

        i = 2
        while True:
            candidate = f"{base}JSON{i}"
            if candidate not in c["props"]:
                return candidate
            i += 1

    def analyze_object(obj, class_full):
        for k, v in obj.items():
            original_json_name = str(k)
            json_name_for_mapping = original_json_name

            # 1) normalizar nombre (sin "_")
            prop = sanitize_identifier(original_json_name)

            # 2) regla especial: no usar "id"
            if prop.lower() == "id":
                prop = "idJSON"
                json_name_for_mapping = "id"

            # 3) regla FHIR: campos companion que empiezan por "_" (p.ej. _family)
            #    Si existe el campo base (sin '_') en la clase, usar base + 'JSON'
            if original_json_name.startswith("_"):
                base_key = sanitize_identifier(original_json_name[1:])  # "_family" -> "family"
                if base_key and base_key in classes[class_full]["props"]:
                    prop = base_key + "JSON"
                    json_name_for_mapping = original_json_name
                else:
                    prop = sanitize_identifier(original_json_name)
                    json_name_for_mapping = original_json_name

            # 4) palabra reservada SQL => añadir "JSON"
            if is_sql_reserved(prop):
                if not prop.endswith("JSON"):
                    prop = prop + "JSON"
                json_name_for_mapping = original_json_name

            # 5) evitar colisiones generales (p.ej. family vs _family al normalizar, a-b vs ab, etc.)
            prop = unique_prop_name(class_full, prop, json_name_for_mapping)

            analyze_value(v, class_full, prop, json_name_for_mapping)

    def analyze_array(arr, class_full, prop, json_name):
        if not arr:
            set_prop(class_full, prop, json_name, ("list", "%String"))
            return

        all_dict = True
        any_dict = False
        for el in arr:
            if isinstance(el, dict):
                any_dict = True
            else:
                all_dict = False

        if any_dict and all_dict:
            # la clase del elemento depende del padre (class_full)
            # usa json_name para el nombre de clase (evita nombres raros tipo Familyjson)
            elem_class_name = to_class_name(json_name)
            elem_full = f"{class_full}.{elem_class_name}"
            ensure_class(elem_full, "serial")
            for el in arr:
                analyze_object(el, elem_full)
            set_prop(class_full, prop, json_name, ("list_serial", elem_full))
            return

        if any_dict and not all_dict:
            set_prop(class_full, prop, json_name, ("list", "%String"))
            return

        merged = None
        for el in arr:
            t = scalar_type(el)
            merged = merge_types(merged, t)
        if merged is None:
            merged = "%String"
        set_prop(class_full, prop, json_name, ("list", merged))

    def analyze_value(v, class_full, prop, json_name):
        if isinstance(v, dict):
            # la clase hija depende del padre (class_full)
            # usa json_name para el nombre de clase (evita nombres raros tipo Familyjson)
            child_class_name = to_class_name(json_name)
            child_full = f"{class_full}.{child_class_name}"
            ensure_class(child_full, "serial")
            analyze_object(v, child_full)
            set_prop(class_full, prop, json_name, ("serial", child_full))
        elif isinstance(v, list):
            analyze_array(v, class_full, prop, json_name)
        else:
            t = scalar_type(v) or "%String"
            set_prop(class_full, prop, json_name, ("scalar", t))

    data = _json.loads(json_text)
    if not isinstance(data, dict):
        data = {"value": data}

    # raíz sigue en basePackage
    root_full = f"{basePackage}.{to_class_name(rootClassName)}"
    ensure_class(root_full, "persistent")
    analyze_object(data, root_full)

    def os_quote(s: str) -> str:
        # escape " as "" for ObjectScript string literals in params
        return str(s).replace('"', '""')

    def emit_property(prop, meta):
        json_name = meta["json_name"]
        k, v = meta["type_spec"]

        needs_map = (json_name is not None and str(json_name) != str(prop))

        def string_base(with_map: bool) -> str:
            if with_map:
                return f'%String(MAXLEN="", %JSONFIELDNAME = "{os_quote(json_name)}")'
            return '%String(MAXLEN="")'

        # Construir type_str
        if k == "scalar":
            if v == "%String":
                type_str = string_base(needs_map)  # %JSONFIELDNAME dentro del tipo
                prop_params = ""                   # y NO como params de propiedad
            else:
                type_str = v
                prop_params = f' (%JSONFIELDNAME = "{os_quote(json_name)}")' if needs_map else ""

        elif k == "list":
            if v == "%String":
                type_str = f'list Of {string_base(False)}'  # list Of %String(MAXLEN="")
                prop_params = f' (%JSONFIELDNAME = "{os_quote(json_name)}")' if needs_map else ""
            else:
                type_str = f"list Of {v}"
                prop_params = f' (%JSONFIELDNAME = "{os_quote(json_name)}")' if needs_map else ""

        elif k == "serial":
            type_str = v
            prop_params = f' (%JSONFIELDNAME = "{os_quote(json_name)}")' if needs_map else ""

        elif k == "list_serial":
            type_str = f"list Of {v}"
            prop_params = f' (%JSONFIELDNAME = "{os_quote(json_name)}")' if needs_map else ""

        else:
            type_str = '%String(MAXLEN="")'
            prop_params = ""

        return f"Property {prop} As {type_str}{prop_params};"


    def emit_class(full_name, meta):
        base_extends = "%Persistent" if meta["kind"] == "persistent" else "%SerialObject"
        extends = f"({base_extends} , %JSON.Adaptor)"

        lines = [f"Class {full_name} Extends {extends}", "{"]
        for prop in meta["order"]:
            lines.append(emit_property(prop, meta["props"][prop]))
            lines.append("")
        lines.append("}")
        return "\n".join(lines).rstrip() + "\n"

    # serials first, then persistent
    ordered = []
    for cn, meta in classes.items():
        if meta["kind"] == "serial":
            ordered.append((cn, meta))
    for cn, meta in classes.items():
        if meta["kind"] == "persistent":
            ordered.append((cn, meta))

    # Ensure output directory exists
    out_path = os.path.normpath(outDir)
    os.makedirs(out_path, exist_ok=True)

    written = ""
    for cn, meta in ordered:
        content = emit_class(cn, meta)
        fname = cn.replace(".", "_") + ".cls"
        fpath = os.path.join(out_path, fname)

        with open(fpath, "w", encoding="utf-8", newline="\n") as f:
            f.write(content)
            written += " " + fpath

    return written
}

/// Crea y rellena una instancia de className a partir de un JSON.
/// Requiere que className extienda de %JSON.Adaptor (como las clases generadas).
ClassMethod NewInstanceFromJSON(json As %String, className As %String) As %RegisteredObject
{
    #dim obj As %RegisteredObject
    #dim sc As %Status

    if className="" {
        throw ##class(%Exception.General).%New("className is required")
    }

    // Crear instancia dinámica por nombre de clase
    set obj = $classmethod(className, "%New")
    if obj="" {
        throw ##class(%Exception.General).%New("Unable to instantiate class: "_className)
    }

    // Importar JSON (usa %JSONFIELDNAME, y genera objetos anidados automáticamente)
    set sc = obj.%JSONImport(json)
    if $$$ISERR(sc) {
        throw ##class(%Exception.StatusException).CreateFromStatus(sc)
    }

    quit obj
}

}
