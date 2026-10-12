package com.jadeonmesh.meshcore.atak.core;

import java.io.StringReader;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import javax.xml.parsers.DocumentBuilder;
import javax.xml.parsers.DocumentBuilderFactory;

import org.w3c.dom.Document;
import org.w3c.dom.Element;
import org.w3c.dom.NamedNodeMap;
import org.w3c.dom.Node;
import org.w3c.dom.NodeList;
import org.xml.sax.InputSource;

/** A small mutable XML element tree for building and reading CoT. */
public final class XNode {
    public final String name;
    public final Map<String, String> attrs = new LinkedHashMap<>();
    public final List<XNode> children = new ArrayList<>();
    public String text = "";

    public XNode(String name) {
        this.name = name;
    }

    public XNode attr(String k, String v) {
        if (v != null)
            attrs.put(k, v);
        return this;
    }

    public String get(String k) {
        return attrs.get(k);
    }

    public String get(String k, String def) {
        String v = attrs.get(k);
        return v == null ? def : v;
    }

    public XNode text(String t) {
        this.text = t == null ? "" : t;
        return this;
    }

    /** Appends and returns a new child. */
    public XNode add(String childName) {
        XNode c = new XNode(childName);
        children.add(c);
        return c;
    }

    public XNode add(XNode child) {
        children.add(child);
        return this;
    }

    public XNode child(String n) {
        for (XNode c : children)
            if (c.name.equals(n))
                return c;
        return null;
    }

    public List<XNode> all(String n) {
        List<XNode> out = new ArrayList<>();
        for (XNode c : children)
            if (c.name.equals(n))
                out.add(c);
        return out;
    }

    /** Child text or attribute lookups along a path like "detail/contact". */
    public XNode path(String p) {
        XNode cur = this;
        for (String part : p.split("/")) {
            if (cur == null)
                return null;
            cur = cur.child(part);
        }
        return cur;
    }

    public String toXml() {
        StringBuilder sb = new StringBuilder(256);
        write(sb);
        return sb.toString();
    }

    private void write(StringBuilder sb) {
        sb.append('<').append(name);
        for (Map.Entry<String, String> e : attrs.entrySet()) {
            sb.append(' ').append(e.getKey()).append("=\"")
                    .append(escape(e.getValue(), true)).append('"');
        }
        if (children.isEmpty() && text.isEmpty()) {
            sb.append("/>");
            return;
        }
        sb.append('>');
        sb.append(escape(text, false));
        for (XNode c : children)
            c.write(sb);
        sb.append("</").append(name).append('>');
    }

    public static String escape(String s, boolean attr) {
        StringBuilder sb = new StringBuilder(s.length() + 8);
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '&':
                    sb.append("&amp;");
                    break;
                case '<':
                    sb.append("&lt;");
                    break;
                case '>':
                    sb.append("&gt;");
                    break;
                case '"':
                    sb.append(attr ? "&quot;" : "\"");
                    break;
                case '\'':
                    sb.append(attr ? "&apos;" : "'");
                    break;
                default:
                    if (c < 0x20 && c != '\n' && c != '\r' && c != '\t')
                        continue; // not legal in XML 1.0
                    sb.append(c);
            }
        }
        return sb.toString();
    }

    /** Parses one XML document's root element, or null if malformed. */
    public static XNode parse(String xml) {
        try {
            DocumentBuilderFactory f = DocumentBuilderFactory.newInstance();
            f.setNamespaceAware(false);
            f.setExpandEntityReferences(false);
            try {
                f.setFeature(
                        "http://apache.org/xml/features/disallow-doctype-decl",
                        true);
            } catch (Exception ignored) {
                // Not every parser knows the feature; CoT never has a DTD.
            }
            DocumentBuilder b = f.newDocumentBuilder();
            Document d = b.parse(new InputSource(new StringReader(xml)));
            return from(d.getDocumentElement());
        } catch (Exception e) {
            return null;
        }
    }

    private static XNode from(Element e) {
        XNode n = new XNode(e.getTagName());
        NamedNodeMap a = e.getAttributes();
        for (int i = 0; i < a.getLength(); i++) {
            Node at = a.item(i);
            n.attrs.put(at.getNodeName(), at.getNodeValue());
        }
        StringBuilder text = new StringBuilder();
        NodeList kids = e.getChildNodes();
        for (int i = 0; i < kids.getLength(); i++) {
            Node k = kids.item(i);
            if (k.getNodeType() == Node.ELEMENT_NODE)
                n.children.add(from((Element) k));
            else if (k.getNodeType() == Node.TEXT_NODE
                    || k.getNodeType() == Node.CDATA_SECTION_NODE)
                text.append(k.getNodeValue());
        }
        n.text = n.children.isEmpty() ? text.toString()
                : text.toString().trim();
        return n;
    }
}
