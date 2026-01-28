# JSON to ObjectScript Class Generator

![image](https://github.com/intersystems-ib/json2class/blob/main/images/json2class.png)

## 1. Environment and Deployment

This project is designed to run on **InterSystems IRIS Community Edition**, using **Docker Compose** as the deployment mechanism.

### IRIS Version

* **InterSystems IRIS Community Edition**
* Any recent IRIS Community version with **Embedded Python** support is valid (IRIS 2022.x or later is recommended).

### Docker & Docker Compose Deployment

The deployment is based on **Docker Compose**. The IRIS Community image itself is defined in a local **Dockerfile**, which allows customization (for example, installing Python dependencies or loading initial code).

The project structure is:

```
.

├── iris
│   └── Dockerfile
│   └── src/
│   └── shared/
└── docker-compose.yml
```

* The `Dockerfile` defines the base image `intersystems/iris-community`.
* The `docker-compose.yml` file orchestrates the container and volume mappings.
* The directory `shared/` is mounted inside the container as `/shared`.

### Docker Compose Usage

To build and start the environment, execute the following commands:

```bash
docker compose build
```

This command builds the IRIS Community image using the local `Dockerfile`.

```bash
docker compose up -d
```

This starts IRIS Community in detached mode.

The generated ObjectScript classes will be written by default to:

```
/shared/generated
```

which is mapped to the host filesystem through Docker volumes.

---

## 2. Purpose of the Code

The purpose of this component is to **convert a JSON document into ObjectScript classes for InterSystems IRIS**, automatically generating:

* **One persistent root class** (`%Persistent`)
* **Multiple serialized classes** (`%SerialObject`) for nested JSON objects

All generated classes:

* Also extend **`%JSON.Adaptor`**
* Explicitly map JSON fields using **`%JSONFIELDNAME`** when required
* Are written directly as `.cls` files, ready for compilation

The generation process is designed to avoid:

* UTF-8 encoding issues
* Conflicts with SQL reserved words
* Invalid ObjectScript property names
* Cross-dependencies between generated classes

---

## 3. Main Class and Public API

All functionality is encapsulated in the class:

```
Utils.JSON2Class
```

### Public Method

```objectscript
ClassMethod Convert(
    json As %String,
    basePackage As %String = "App.Model",
    rootClassName As %String = "Root",
    outDir As %String = "/shared/generated"
) As %String
```

### Parameters

| Parameter       | Description                                                |
| --------------- | ---------------------------------------------------------- |
| `json`          | Input JSON document as a string                            |
| `basePackage`   | Base package name for generated classes (e.g. `App.Model`) |
| `rootClassName` | Name of the root class (first JSON level)                  |
| `outDir`        | Directory where `.cls` files will be generated             |

### Return Value

* Returns a **string** containing the list of generated `.cls` file paths.

---

## 4. Generation Output

### 4.1 Root Persistent Class

The **top-level JSON object** is converted into a class that:

* Extends:

  ```
  %Persistent, %JSON.Adaptor
  ```
* Represents the main entity of the model

Example:

```objectscript
Class App.Model.Person Extends (%Persistent , %JSON.Adaptor)
{
Property name As %String;
Property age As %Integer;
Property address As App.Model.Person.Address;
}
```

---

### 4.2 Nested Serialized Classes

Each nested JSON object generates a class that:

* Extends:

  ```
  %SerialObject, %JSON.Adaptor
  ```
* Is named by concatenating the **parent class name** and the **property name**

Example for a nested `address` object:

```objectscript
Class App.Model.Person.Address Extends (%SerialObject , %JSON.Adaptor)
{
Property street As %String;
Property city As %String;
}
```

This naming strategy avoids cross-dependencies and ensures a clear hierarchy.

---

## 5. Special Rules Applied

### 5.1 Property Naming

* All non-alphanumeric characters (including `_`) are removed
* Example:

  ```
  terminology_id  →  terminologyid
  ```

### 5.2 Explicit JSON Mapping

Whenever the property name differs from the original JSON field, the following mapping is added:

```objectscript
(%JSONFIELDNAME = "original_name")
```

Example:

```objectscript
Property terminologyid As %String (%JSONFIELDNAME = "terminology_id");
```

### 5.3 `id` Field Handling

If a property is named `id`, it is automatically transformed into:

```objectscript
Property idJSON As %Integer (%JSONFIELDNAME = "id");
```

### 5.4 SQL Reserved Words

If a property name matches an IRIS SQL reserved word (case-insensitive):

* The suffix `JSON` is appended
* The original JSON name is preserved using `%JSONFIELDNAME`

Example:

```objectscript
Property orderJSON As %String (%JSONFIELDNAME = "order");
```

---

## 6. Execution Flow

1. The `Convert` method receives a JSON string
2. The JSON is normalized and passed to Embedded Python using Base64
3. The JSON structure is analyzed recursively
4. The generator creates:

   * One `%Persistent` root class
   * Multiple `%SerialObject` classes
5. `.cls` files are written to the configured output directory
6. Files are ready to be compiled in IRIS

---

## 7. Typical Usage Example

```objectscript
set json = {\"name\":\"Ana\",\"age\":32,\"address\":{\"street\":\"X\"}}
set files = ##class(Utils.JSON2Class).Convert(json.%ToJSON(),"App.Model","Person")
write files
```

The generated classes will appear in:

```
/shared/generated
```
And compiled in the server below the defined package.
---

This component significantly accelerates the creation of ObjectScript domain models from JSON contracts, ensuring consistency, safety, and full compatibility with InterSystems IRIS.
