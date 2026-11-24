using System.Collections;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Markup;
using System.Windows.Media;

namespace ThemeEquivalence;

/// <summary>
/// Structural comparison of two theme dictionaries: the BAML one and the XSG-compiled one. Templates are compared through the tree they
/// instantiate (LoadContent), because BAML keeps template content as XAML while the generator builds FrameworkElementFactory trees.
/// Every difference is a line "path: what" (the path starts at the dictionary key).
/// </summary>
internal sealed class Differ
{
    private readonly List<string> _diffs = new();
    private readonly HashSet<(object, object)> _seen = new(new PairComparer());
    public IReadOnlyList<string> Diffs => _diffs;
    private ResourceDictionary? _xsgRoot;
    // The XSG-side resource dictionaries in scope (a style's or template's own .Resources first, then the theme): where a lazily resolved key is looked up.
    private readonly List<ResourceDictionary> _scopes = new();

    private object? ResolveXsg(object key)
    {
        for (var i = _scopes.Count - 1; i >= 0; i--) if (_scopes[i].Contains(key)) return _scopes[i][key];
        return _xsgRoot is not null && _xsgRoot.Contains(key) ? _xsgRoot[key] : null;
    }

    private static object? ResourceKeyOf(Expression e) =>
        e.GetType().GetProperty("ResourceKey", BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public)?.GetValue(e);
    public int KeysCompared;
    public readonly List<string> Excluded = new();
    // Type names whose resources the XSG theme leaves out on purpose (LibreWpfXsgExcludeTargetTypes: printing is Windows-only).
    public HashSet<string> ExcludedTypes { get; init; } = new();

    private void Diff(string path, string what) => _diffs.Add($"{path}: {what}");

    public void CompareDictionaries(ResourceDictionary baml, ResourceDictionary xsg)
    {
        _xsgRoot ??= xsg;
        var bamlKeys = KeyMap(baml);
        var xsgKeys = KeyMap(xsg);
        foreach (var key in bamlKeys.Keys.Except(xsgKeys.Keys).OrderBy(k => k))
        {
            if (ExcludedTypes.Any(t => key.EndsWith("." + t, StringComparison.Ordinal))) Excluded.Add(key);
            else Diff(key, "only in BAML");
        }
        foreach (var key in xsgKeys.Keys.Except(bamlKeys.Keys).OrderBy(k => k)) Diff(key, "only in XSG");
        foreach (var key in bamlKeys.Keys.Intersect(xsgKeys.Keys).OrderBy(k => k))
        {
            KeysCompared++;
            object? a = null, b = null;
            try { a = baml[bamlKeys[key]]; } catch (Exception e) { Diff(key, "BAML value failed: " + e.GetType().Name + ": " + e.Message); continue; }
            try { b = xsg[xsgKeys[key]]; } catch (Exception e) { Diff(key, "XSG value failed: " + e.GetType().Name + ": " + e.Message); continue; }
            Compare(key, a, b, 0);
        }
    }

    private static Dictionary<string, object> KeyMap(ResourceDictionary dictionary)
    {
        var map = new Dictionary<string, object>();
        foreach (var key in dictionary.Keys.Cast<object>()) map[KeyText(key)] = key;
        foreach (var merged in dictionary.MergedDictionaries)
        {
            foreach (var pair in KeyMap(merged)) map.TryAdd(pair.Key, pair.Value);
        }
        return map;
    }

    private static string KeyText(object? key) => key switch
    {
        null => "(null)",
        Type t => "type:" + t.FullName,
        ComponentResourceKey c => "component:" + c.TypeInTargetAssembly?.FullName + "/" + c.ResourceId,
        DataTemplateKey d => "datatemplate:" + (d.DataType as Type)?.FullName,
        string s => s,
        _ => key.GetType().Name + ":" + key,
    };

    public void Compare(string path, object? a, object? b, int depth)
    {
        if (depth > 40) return;
        if (a is null || b is null)
        {
            if (!(a is null && b is null)) Diff(path, $"{Show(a)} vs {Show(b)}");
            return;
        }

        // StaticResource of a key the generator resolves lazily is a resource reference there and the resolved object in BAML.
        if (b is Expression be && a is not Expression && ResourceKeyOf(be) is { } key && ResolveXsg(key) is { } resolved)
        {
            Compare(path, a, resolved, depth + 1);
            return;
        }
        if (a.GetType() != b.GetType())
        {
            if (!(a is string or IConvertible && Show(a) == Show(b))) Diff(path, $"type {a.GetType().Name} vs {b.GetType().Name}");
            return;
        }

        if (!a.GetType().IsValueType && a is not string && !_seen.Add((a, b))) return;

        switch (a)
        {
            case string or Type or Enum or ValueType when a.GetType().IsPrimitive || a is string or Type or Enum or decimal:
                if (!a.Equals(b)) Diff(path, $"{Show(a)} vs {Show(b)}");
                return;
            case ComponentResourceKey ak:
                if (KeyText(ak) != KeyText(b)) Diff(path, $"{KeyText(ak)} vs {KeyText(b)}");
                return;
            case ResourceDictionary ad:
                CompareDictionaries(ad, (ResourceDictionary)b);
                return;
            case Style astyle:
                CompareStyle(path, astyle, (Style)b, depth);
                return;
            case FrameworkTemplate atemplate:
                CompareTemplate(path, atemplate, (FrameworkTemplate)b, depth);
                return;
            case TriggerBase atrigger:
                CompareTrigger(path, atrigger, (TriggerBase)b, depth);
                return;
            case SetterBase asetter:
                CompareSetter(path, asetter, (SetterBase)b, depth);
                return;
            case Condition acondition:
                var bcondition = (Condition)b;
                Compare(path + ".Property", acondition.Property?.Name, bcondition.Property?.Name, depth + 1);
                Compare(path + ".Value", acondition.Value, bcondition.Value, depth + 1);
                Compare(path + ".SourceName", acondition.SourceName, bcondition.SourceName, depth + 1);
                Compare(path + ".Binding", acondition.Binding, bcondition.Binding, depth + 1);
                return;
            case BindingBase abinding:
                CompareBinding(path, abinding, (BindingBase)b, depth);
                return;
            case DependencyObject ado:
                CompareDependencyObject(path, ado, (DependencyObject)b, depth);
                return;
            case TemplateBindingExtension ate:
                Compare(path + ".Property", ate.Property?.Name, ((TemplateBindingExtension)b).Property?.Name, depth + 1);
                return;
            case DynamicResourceExtension adr:
                Compare(path + ".ResourceKey", KeyText(adr.ResourceKey), KeyText(((DynamicResourceExtension)b).ResourceKey), depth + 1);
                return;
            case Expression ae:
                CompareExpression(path, ae, (Expression)b, depth);
                return;
            case IEnumerable ae2 when a is not string:
                CompareSequences(path, ae2.Cast<object?>().ToList(), ((IEnumerable)b).Cast<object?>().ToList(), depth);
                return;
            default:
                if (a.GetType().IsValueType)
                {
                    if (!a.Equals(b)) Diff(path, $"{Show(a)} vs {Show(b)}");
                }
                else if (Show(a) != Show(b))
                {
                    Diff(path, $"{a.GetType().Name} {Show(a)} vs {Show(b)}");
                }
                return;
        }
    }

    private void CompareSequences(string path, List<object?> a, List<object?> b, int depth)
    {
        if (a.Count != b.Count) Diff(path, $"count {a.Count} vs {b.Count}");
        for (var i = 0; i < Math.Min(a.Count, b.Count); i++) Compare($"{path}[{i}]", a[i], b[i], depth + 1);
    }

    private void CompareStyle(string path, Style a, Style b, int depth)
    {
        _scopes.Add(b.Resources);
        try { CompareStyleCore(path, a, b, depth); } finally { _scopes.RemoveAt(_scopes.Count - 1); }
    }

    private void CompareStyleCore(string path, Style a, Style b, int depth)
    {
        Compare(path + ".TargetType", a.TargetType, b.TargetType, depth + 1);
        Compare(path + ".BasedOn", a.BasedOn?.TargetType, b.BasedOn?.TargetType, depth + 1);
        CompareSequences(path + ".Setters", a.Setters.Cast<object?>().ToList(), b.Setters.Cast<object?>().ToList(), depth);
        CompareSequences(path + ".Triggers", a.Triggers.Cast<object?>().ToList(), b.Triggers.Cast<object?>().ToList(), depth);
        if (a.Resources.Count != b.Resources.Count || a.Resources.MergedDictionaries.Count != b.Resources.MergedDictionaries.Count)
        {
            Diff(path + ".Resources", $"count {a.Resources.Count} vs {b.Resources.Count}");
        }
        else
        {
            CompareDictionaries(a.Resources, b.Resources);
        }
    }

    private void CompareSetter(string path, SetterBase a, SetterBase b, int depth)
    {
        switch (a)
        {
            case Setter sa:
                var sb = (Setter)b;
                Compare(path + ".Property", DpName(sa.Property), DpName(sb.Property), depth + 1);
                Compare(path + ".TargetName", sa.TargetName, sb.TargetName, depth + 1);
                Compare(path + ".Value", sa.Value, sb.Value, depth + 1);
                break;
            case EventSetter ea:
                var eb = (EventSetter)b;
                Compare(path + ".Event", ea.Event?.Name, eb.Event?.Name, depth + 1);
                Compare(path + ".Handler", ea.Handler?.Method.Name, eb.Handler?.Method.Name, depth + 1);
                break;
        }
    }

    private void CompareTrigger(string path, TriggerBase a, TriggerBase b, int depth)
    {
        switch (a)
        {
            case Trigger ta:
                var tb = (Trigger)b;
                Compare(path + ".Property", DpName(ta.Property), DpName(tb.Property), depth + 1);
                Compare(path + ".Value", ta.Value, tb.Value, depth + 1);
                Compare(path + ".SourceName", ta.SourceName, tb.SourceName, depth + 1);
                CompareSequences(path + ".Setters", ta.Setters.Cast<object?>().ToList(), tb.Setters.Cast<object?>().ToList(), depth);
                break;
            case MultiTrigger ma:
                var mb = (MultiTrigger)b;
                CompareSequences(path + ".Conditions", ma.Conditions.Cast<object?>().ToList(), mb.Conditions.Cast<object?>().ToList(), depth);
                CompareSequences(path + ".Setters", ma.Setters.Cast<object?>().ToList(), mb.Setters.Cast<object?>().ToList(), depth);
                break;
            case DataTrigger da:
                var db = (DataTrigger)b;
                Compare(path + ".Binding", da.Binding, db.Binding, depth + 1);
                Compare(path + ".Value", da.Value, db.Value, depth + 1);
                CompareSequences(path + ".Setters", da.Setters.Cast<object?>().ToList(), db.Setters.Cast<object?>().ToList(), depth);
                break;
            case MultiDataTrigger mda:
                var mdb = (MultiDataTrigger)b;
                CompareSequences(path + ".Conditions", mda.Conditions.Cast<object?>().ToList(), mdb.Conditions.Cast<object?>().ToList(), depth);
                CompareSequences(path + ".Setters", mda.Setters.Cast<object?>().ToList(), mdb.Setters.Cast<object?>().ToList(), depth);
                break;
            case EventTrigger ea:
                var eb = (EventTrigger)b;
                Compare(path + ".RoutedEvent", ea.RoutedEvent?.Name, eb.RoutedEvent?.Name, depth + 1);
                Compare(path + ".SourceName", ea.SourceName, eb.SourceName, depth + 1);
                CompareSequences(path + ".Actions", ea.Actions.Cast<object?>().ToList(), eb.Actions.Cast<object?>().ToList(), depth);
                break;
        }

        // Enter/exit actions (storyboards): compare their count and kinds.
        CompareSequences(path + ".EnterActions", a.EnterActions.Cast<object?>().ToList(), b.EnterActions.Cast<object?>().ToList(), depth);
        CompareSequences(path + ".ExitActions", a.ExitActions.Cast<object?>().ToList(), b.ExitActions.Cast<object?>().ToList(), depth);
    }

    private void CompareTemplate(string path, FrameworkTemplate a, FrameworkTemplate b, int depth)
    {
        var resources = b.Resources;
        if (resources is not null) _scopes.Add(resources);
        try { CompareTemplateCore(path, a, b, depth); } finally { if (resources is not null) _scopes.RemoveAt(_scopes.Count - 1); }
    }

    private void CompareTemplateCore(string path, FrameworkTemplate a, FrameworkTemplate b, int depth)
    {
        if (a is ControlTemplate ca)
        {
            var cb = (ControlTemplate)b;
            Compare(path + ".TargetType", ca.TargetType, cb.TargetType, depth + 1);
            CompareSequences(path + ".Triggers", ca.Triggers.Cast<object?>().ToList(), cb.Triggers.Cast<object?>().ToList(), depth);
        }
        else if (a is DataTemplate da)
        {
            var db = (DataTemplate)b;
            Compare(path + ".DataType", da.DataType, db.DataType, depth + 1);
            CompareSequences(path + ".Triggers", da.Triggers.Cast<object?>().ToList(), db.Triggers.Cast<object?>().ToList(), depth);
        }

        DependencyObject? ra = null, rb = null;
        // <ControlTemplate.Resources>: the dictionaries the template carries itself.
        if (a.Resources is { } resourcesA && b.Resources is { } resourcesB) Compare(path + ".Resources", resourcesA, resourcesB, depth + 1);
        else if ((a.Resources is null) != (b.Resources is null)) Diff(path + ".Resources", $"{Show(a.Resources)} vs {Show(b.Resources)}");
        Seal(path + " (BAML)", a);
        Seal(path + " (XSG)", b);
        try { ra = a.LoadContent(); } catch (Exception e) { Diff(path + ".Content", "BAML LoadContent failed: " + e.GetType().Name + ": " + e.Message); }
        try { rb = b.LoadContent(); } catch (Exception e) { Diff(path + ".Content", "XSG LoadContent failed: " + e.GetType().Name + ": " + e.Message); }
        if (ra is not null && rb is not null) CompareTree(path + ".Content", ra, rb, depth);
    }

    // A template made of FrameworkElementFactory nodes can be instantiated only once sealed (WPF seals it when an element first applies it).
    private void Seal(string path, FrameworkTemplate template)
    {
        try { if (!template.IsSealed) template.Seal(); }
        catch (Exception e) { Diff(path, "Seal failed: " + e.GetType().Name + ": " + e.Message); }
    }

    private void CompareTree(string path, DependencyObject a, DependencyObject b, int depth)
    {
        // An element's own .Resources (the XSG side) is where a StaticResource of a key declared on that element or above is resolved from.
        var own = b is FrameworkElement fe && fe.Resources.Count > 0 ? fe.Resources : null;
        if (own is not null) _scopes.Add(own);
        try { CompareTreeCore(path, a, b, depth); } finally { if (own is not null) _scopes.RemoveAt(_scopes.Count - 1); }
    }

    private void CompareTreeCore(string path, DependencyObject a, DependencyObject b, int depth)
    {
        CompareDependencyObject(path, a, b, depth, inTree: true);
        var ca = Children(a);
        var cb = Children(b);
        if (ca.Count != cb.Count) Diff(path, $"children {ca.Count} vs {cb.Count}");
        for (var i = 0; i < Math.Min(ca.Count, cb.Count); i++) CompareTree($"{path}/{ca[i].GetType().Name}[{i}]", ca[i], cb[i], depth + 1);
    }

    private static List<DependencyObject> Children(DependencyObject parent)
    {
        var list = new List<DependencyObject>();
        if (parent is Visual or System.Windows.Media.Media3D.Visual3D)
        {
            for (var i = 0; i < VisualTreeHelper.GetChildrenCount(parent); i++) list.Add(VisualTreeHelper.GetChild(parent, i));
        }
        if (list.Count == 0)
        {
            foreach (var child in LogicalTreeHelper.GetChildren(parent)) if (child is DependencyObject d) list.Add(d);
        }
        return list;
    }

    private void CompareDependencyObject(string path, DependencyObject a, DependencyObject b, int depth, bool inTree = false)
    {
        var la = Locals(a);
        var lb = Locals(b);
        foreach (var name in la.Keys.Except(lb.Keys).OrderBy(k => k))
        {
            // BAML stores the x:Name of a template node as the Name property and gives the root a NameScope; a FrameworkElementFactory tree keeps
            // names in the template (FindName and ElementName resolve through it), so neither is a local value there.
            if (name == "FrameworkElement.Name" || name.EndsWith("NameScope.NameScope", StringComparison.Ordinal)) continue;
            Diff($"{path}.{name}", $"only in BAML ({Show(la[name])})");
        }
        foreach (var name in lb.Keys.Except(la.Keys).OrderBy(k => k)) Diff($"{path}.{name}", $"only in XSG ({Show(lb[name])})");
        foreach (var name in la.Keys.Intersect(lb.Keys).OrderBy(k => k)) Compare($"{path}.{name}", la[name], lb[name], depth + 1);
        if (a is FrameworkElement fa && b is FrameworkElement fb && fa.Resources.Count != fb.Resources.Count) Diff(path + ".Resources", $"count {fa.Resources.Count} vs {fb.Resources.Count}");
    }

    private static Dictionary<string, object?> Locals(DependencyObject d)
    {
        var map = new Dictionary<string, object?>();
        var e = d.GetLocalValueEnumerator();
        while (e.MoveNext())
        {
            var entry = e.Current;
            if (entry.Value == DependencyProperty.UnsetValue) continue;
            map[DpName(entry.Property)] = entry.Value;
        }
        return map;
    }

    private static string DpName(DependencyProperty? p) => p is null ? "(null)" : p.OwnerType.Name + "." + p.Name;

    private void CompareBinding(string path, BindingBase a, BindingBase b, int depth)
    {
        switch (a)
        {
            case Binding ba:
                var bb = (Binding)b;
                Compare(path + ".Path", PathText(ba.Path), PathText(bb.Path), depth + 1);
                Compare(path + ".Mode", ba.Mode, bb.Mode, depth + 1);
                Compare(path + ".ElementName", ba.ElementName, bb.ElementName, depth + 1);
                Compare(path + ".RelativeSource.Mode", ba.RelativeSource?.Mode, bb.RelativeSource?.Mode, depth + 1);
                Compare(path + ".RelativeSource.AncestorType", ba.RelativeSource?.AncestorType, bb.RelativeSource?.AncestorType, depth + 1);
                Compare(path + ".Converter", ba.Converter?.GetType().FullName, bb.Converter?.GetType().FullName, depth + 1);
                Compare(path + ".ConverterParameter", ba.ConverterParameter, bb.ConverterParameter, depth + 1);
                Compare(path + ".StringFormat", ba.StringFormat, bb.StringFormat, depth + 1);
                Compare(path + ".UpdateSourceTrigger", ba.UpdateSourceTrigger, bb.UpdateSourceTrigger, depth + 1);
                break;
            case MultiBinding ma:
                var mb = (MultiBinding)b;
                Compare(path + ".Converter", ma.Converter?.GetType().FullName, mb.Converter?.GetType().FullName, depth + 1);
                CompareSequences(path + ".Bindings", ma.Bindings.Cast<object?>().ToList(), mb.Bindings.Cast<object?>().ToList(), depth);
                break;
            default:
                Compare(path + ".Kind", a.GetType().Name, b.GetType().Name, depth + 1);
                break;
        }
    }

    // The generator writes a compiled path as "(0).(1)" plus parameters (DependencyProperty / PropertyDescriptor / PropertyInfo): the same path as the text BAML keeps.
    private static string PathText(PropertyPath? path)
    {
        if (path is null || string.IsNullOrEmpty(path.Path)) return "";
        var parameters = path.PathParameters;
        // "(Owner.Prop)" and "Prop" name the same property of the source: compare by the property name.
        string Simplify(string text) => System.Text.RegularExpressions.Regex.Replace(text, @"\(([A-Za-z_][A-Za-z0-9_]*)\.([A-Za-z_][A-Za-z0-9_]*)\)", "$2");
        if (parameters.Count == 0) return Simplify(path.Path);
        return System.Text.RegularExpressions.Regex.Replace(path.Path, @"\((\d+)\)", m =>
        {
            var parameter = parameters[int.Parse(m.Groups[1].Value)];
            return parameter switch
            {
                DependencyProperty dp => dp.Name,
                System.ComponentModel.PropertyDescriptor pd => pd.Name,
                PropertyInfo pi => pi.Name,
                _ => m.Value,
            };
        });
    }

    private void CompareExpression(string path, Expression a, Expression b, int depth)
    {
        if (a is BindingExpressionBase ba)
        {
            Compare(path + ".ParentBindingBase", ba.ParentBindingBase, ((BindingExpressionBase)b).ParentBindingBase, depth + 1);
            return;
        }
        var key = a.GetType().GetProperty("ResourceKey", BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public);
        if (key is not null)
        {
            Compare(path + ".ResourceKey", KeyText(key.GetValue(a)), KeyText(key.GetValue(b)), depth + 1);
            return;
        }
        var ext = a.GetType().GetProperty("TemplateBindingExtension", BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public);
        if (ext is not null)
        {
            Compare(path + ".TemplateBinding", ext.GetValue(a), ext.GetValue(b), depth + 1);
            return;
        }
        Diff(path, "unhandled expression " + a.GetType().Name);
    }

    private static string Show(object? value) => value switch
    {
        null => "null",
        string s => "\"" + s + "\"",
        Type t => "typeof(" + t.Name + ")",
        _ => value.GetType().Name + (value.ToString() is { } text && text != value.GetType().ToString() ? " " + text : ""),
    };

    private sealed class PairComparer : IEqualityComparer<(object, object)>
    {
        public bool Equals((object, object) x, (object, object) y) => ReferenceEquals(x.Item1, y.Item1) && ReferenceEquals(x.Item2, y.Item2);
        public int GetHashCode((object, object) p) => System.Runtime.CompilerServices.RuntimeHelpers.GetHashCode(p.Item1) * 31 + System.Runtime.CompilerServices.RuntimeHelpers.GetHashCode(p.Item2);
    }
}
