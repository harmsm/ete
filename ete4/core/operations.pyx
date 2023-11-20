"""
Tree-related operations.

Sorting, changing the root to a node, moving branches, removing (prunning)...
"""

import random
from collections import namedtuple


def sort(tree, key=None, reverse=False):
    """Sort the tree in-place."""
    key = key or (lambda node: (node.size[1], node.size[0], node.name))

    for node in tree.traverse('postorder'):
        node.children.sort(key=key, reverse=reverse)


def set_outgroup(node, bprops=None):
    """Reroot the tree at the given outgroup node.

    The original root node will be used as the new root node, so any
    reference to it in the code will still be valid.

    :param node: Node where to set root (future first child of the root).
    :param bprops: List of branch properties (other than "dist" and "support").
    """
    old_root = node.root
    positions = node.id  # child positions from root to node (like [1, 0, ...])

    assert_root_consistency(old_root, bprops)
    assert node != old_root, 'cannot set the absolute tree root as outgroup'

    # Make a new node to replace the old root.
    replacement = old_root.__class__()  # could be Tree() or PhyloTree(), etc.

    children = old_root.remove_children()
    replacement.add_children(children)  # take its children

    # Now we can insert the old root, which has no children, in its new place.
    insert_intermediate(node, old_root, bprops)

    root = replacement  # current root, which will change in each iteration
    for child_pos in positions:
        root = rehang(root, child_pos, bprops)

    if len(replacement.children) == 1:
        join_branch(replacement)


def assert_root_consistency(root, bprops=None):
    """Raise AssertionError if the root node of a tree looks inconsistent."""
    assert root.dist in [0, None], 'root has a distance'

    for pname in ['support'] + (bprops or []):
        assert pname not in root.props, f'root has branch property: {pname}'

    if len(root.children) == 2:
        ch1, ch2 = root.children
        s1, s2 = ch1.props.get('support'), ch2.props.get('support')
        assert s1 == s2, 'inconsistent support at the root: %r != %r' % (s1, s2)


def rehang(root, child_pos, bprops):
    """Rehang node on its child at position child_pos and return it."""
    # root === child  ->  child === root
    child = root.pop_child(child_pos)

    child.add_child(root)

    swap_props(root, child, ['dist', 'support'] + (bprops or []))

    return child  # which is now the parent of its previous parent


def swap_props(n1, n2, props):
    """Swap properties between nodes n1 and n2."""
    for pname in props:
        p1 = n1.props.pop(pname, None)
        p2 = n2.props.pop(pname, None)
        if p1 is not None:
            n2.props[pname] = p1
        if p2 is not None:
            n1.props[pname] = p2


def insert_intermediate(node, intermediate, bprops=None):
    """Insert, between node and its parent, an intermediate node."""
    # == up ======= node  ->  == up === intermediate === node
    up = node.up

    pos_in_parent = up.children.index(node)  # save its position in parent
    up.children.pop(pos_in_parent)  # detach from parent

    intermediate.add_child(node)

    if 'dist' in node.props:  # split dist between the new and old nodes
        node.dist = intermediate.dist = node.dist / 2

    for prop in ['support'] + (bprops or []):  # copy other branch props if any
        if prop in node.props:
            intermediate.props[prop] = node.props[prop]

    up.children.insert(pos_in_parent, intermediate)  # put new where old was
    intermediate.up = up


def join_branch(node):
    """Substitute node for its only child."""
    # == node ==== child  ->  ====== child
    assert len(node.children) == 1, 'cannot join branch with multiple children'

    child = node.children[0]

    if 'support' in node.props and 'support' in child.props:
        assert node.support == child.support, \
            'cannot join branches with different support'

    if 'dist' in node.props:
        child.dist = (child.dist or 0) + node.dist  # restore total dist

    up = node.up
    pos_in_parent = up.children.index(node)  # save its position in parent
    up.children.pop(pos_in_parent)  # detach from parent
    up.children.insert(pos_in_parent, child)  # put child where the old node was
    child.up = up


def move(node, shift=1):
    """Change the position of the current node with respect to its parent."""
    # ╴up╶┬╴node     ->  ╴up╶┬╴sibling
    #     ╰╴sibling          ╰╴node
    assert node.up, 'cannot move the root'

    siblings = node.up.children

    pos_old = siblings.index(node)
    pos_new = (pos_old + shift) % len(siblings)

    siblings[pos_old], siblings[pos_new] = siblings[pos_new], siblings[pos_old]


def remove(node):
    """Remove the given node from its tree."""
    assert node.up, 'cannot remove the root'

    parent = node.up
    parent.remove_child(node)


# Functions that used to be defined inside tree.pyx.

def common_ancestor(nodes):
    """Return the last node common to the lineages of the given nodes.

    If the given nodes don't have a common ancestor, it will return None.

    :param nodes: List of nodes whose common ancestor we want to find.
    """
    if not nodes:
        return None

    curr = nodes[0]  # current node being the last common ancestor

    for node in nodes[1:]:
        lin_node = set(node.lineage())
        curr = next((n for n in curr.lineage() if n in lin_node), None)

    return curr  # which is now the last common ancestor of all nodes


def populate(tree, size, names=None, model='yule',
             dist_fn=None, support_fn=None):
    """Populate tree with a dichotomic random topology.

    :param size: Number of leaves to add. All necessary intermediate
        nodes will be created too.
    :param names: Collection (list or set) of names to name the leaves.
        If None, leaves will be named using short letter sequences.
    :param model: Model used to generate the topology. It can be:

        - "yule" or "yule-harding": Every step a randomly selected leaf
          grows two new children.
        - "uniform" or "pda": Every step a randomly selected node (leaf
          or interior) grows a new sister leaf.

    :param dist_fn: Function to produce values to set as distance
        in newly created branches, or None for no distances.
    :param support_fn: Function to produce values to set as support
        in newly created internal branches, or None for no supports.
    """
    assert names is None or len(names) >= size, \
        f'names too small ({len(names)}) for size {size}'

    root = tree if not tree.children else create_dichotomic_sister(tree)

    if model in ['yule', 'yule-harding']:
        populate_yule(root, size)
    elif model in ['uniform', 'pda']:
        populate_uniform(root, size)
    else:
        raise ValueError(f'unknown model: {model}')

    if dist_fn or support_fn:
        add_branch_values(root, dist_fn, support_fn)

    add_leaf_names(root, names)


def create_dichotomic_sister(tree):
    """Make tree start with a dichotomy, with the old tree and a new sister."""
    children = tree.remove_children()  # pass all the children to a connector
    connector = tree.__class__(children=children)
    sister = tree.__class__()  # new sister, dichotomic with the old tree
    tree.add_children([connector, sister])
    return sister


def populate_yule(root, size):
    """Populate with the Yule-Harding model a topology with size leaves."""
    leaves = [root]  # will contain the current leaves
    for _ in range(size - 1):
        leaf = leaves.pop( random.randrange(len(leaves)) )

        node0 = leaf.add_child()
        node1 = leaf.add_child()

        leaves.extend([node0, node1])


def populate_uniform(root, size):
    """Populate with the uniform model a topology with size leaves."""
    if size < 2:
        return

    child0 = root.add_child()
    child1 = root.add_child()

    nodes = [child0]  # without child1, since it is in the same branch!

    for _ in range(size - 2):
        node = random.choice(nodes)  # random node (except root and child1)

        if node is child0 and random.randint(0, 1) == 1:  # 50% chance
            node = child1  # take the other child

        intermediate = root.__class__()  # could be Tree(), PhyloTree()...
        insert_intermediate(node, intermediate)  # ---up---inter---node
        leaf = intermediate.add_child()          # ---up---inter===node,leaf
        random.shuffle(intermediate.children)  # [node,leaf] or [leaf,node]

        nodes.extend([intermediate, leaf])


def add_branch_values(root, dist_fn, support_fn):
    """Add distances and support values to the branches."""
    for node in root.descendants():
        if dist_fn:
            node.dist = dist_fn()
        if support_fn and not node.is_leaf:
            node.support = support_fn()

    # Make sure the children of root have the same support.
    if any(node.support is None for node in root.children):
        for node in root.children:
            node.props.pop('support', None)
    else:
        for node in root.children[1:]:
            node.support = root.children[0].support


def add_leaf_names(root, names):
    """Add names to the leaves."""
    leaves = list(root.leaves())
    random.shuffle(leaves)  # so we name them in no particular order
    if names is not None:
        for node, name in zip(leaves, names):
            node.name = name
    else:
        for i, node in enumerate(leaves):
            node.name = make_name(i)


def make_name(i, chars='abcdefghijklmnopqrstuvwxyz'):
    """Return a short name corresponding to the index i."""
    # 0: 'a', 1: 'b', ..., 25: 'z', 26: 'aa', 27: 'ab', ...
    name = ''
    while i >= 0:
        name = chars[i % len(chars)] + name
        i = i // len(chars) - 1
    return name


def ladderize(tree, topological=False, reverse=False):
    """Sort branches according to the size of each partition.

    :param topological: If True, the distance between nodes will be the
        number of nodes between them (instead of the sum of branch lenghts).
    :param reverse: If True, sort with biggest partitions first.

    Example::

      t = Tree('(f,((d,((a,b),c)),e));')
      print(t)
      #   ╭╴f
      # ──┤     ╭╴d
      #   │  ╭──┤  ╭──┬╴a
      #   ╰──┤  ╰──┤  ╰╴b
      #      │     ╰╴c
      #      ╰╴e

      t.ladderize()
      print(t)
      # ──┬╴f
      #   ╰──┬╴e
      #      ╰──┬╴d
      #         ╰──┬╴c
      #            ╰──┬╴a
      #               ╰╴b
    """
    sizes = {}  # sizes of the nodes

    # Key function for the sort order. Sort by size, then by # of children.
    key = lambda node: (sizes[node], len(node.children))

    # Distance function (branch length to consider for each node).
    dist = ((lambda node: 1) if topological else
            (lambda node: float(node.props.get('dist', 1))))

    for node in tree.traverse('postorder'):
        if node.is_leaf:
            sizes[node] = dist(node)
        else:
            node.children.sort(key=key, reverse=reverse)  # time to sort!

            sizes[node] = dist(node) + max(sizes[n] for n in node.children)

            for n in node.children:
                sizes.pop(n)  # free memory, no need to keep all the sizes


def to_ultrametric(tree, topological=False):
    """Convert tree to ultrametric (all leaves equidistant from root)."""
    tree.dist = tree.dist or 0  # covers common case of not having dist set

    update_sizes_all(tree)  # so node.size[0] are distances to leaves

    dist_full = tree.size[0]  # original distance from root to furthest leaf

    if (topological or dist_full <= 0 or
        any(node.dist is None for node in tree.traverse())):
        # Ignore original distances and just use the tree topology.
        for node in tree.traverse():
            node.dist = 1 if node.up else 0
        update_sizes_all(tree)
        dist_full = dist_full if dist_full > 0 else tree.size[0]

    for node in tree.traverse():
        if node.dist > 0:
            d = sum(n.dist for n in node.ancestors())
            node.dist *= (dist_full - d) / node.size[0]


# Traversing the tree.

# Position on the tree: current node, number of visited children.
TreePos = namedtuple('TreePos', 'node nch')

class Walker:
    """Represents the position when traversing a tree."""

    def __init__(self, root):
        self.visiting = [TreePos(node=root, nch=0)]
        # will look like: [(root, 2), (child2, 5), (child25, 3), (child253, 0)]
        self.descend = True

    def go_back(self):
        self.visiting.pop()
        if self.visiting:
            node, nch = self.visiting[-1]
            self.visiting[-1] = TreePos(node, nch + 1)
        self.descend = True

    @property
    def node(self):
        return self.visiting[-1].node

    @property
    def node_id(self):
        return tuple(branch.nch for branch in self.visiting[:-1])

    @property
    def first_visit(self):
        return self.visiting[-1].nch == 0

    @property
    def has_unvisited_branches(self):
        node, nch = self.visiting[-1]
        return nch < len(node.children)

    def add_next_branch(self):
        node, nch = self.visiting[-1]
        self.visiting.append(TreePos(node=node.children[nch], nch=0))


def walk(tree):
    """Yield an iterator as it traverses the tree."""
    it = Walker(tree)  # node iterator
    while it.visiting:
        if it.first_visit:
            yield it

            if it.node.is_leaf or not it.descend:
                it.go_back()
                continue

        if it.has_unvisited_branches:
            it.add_next_branch()
        else:
            yield it
            it.go_back()


# Size-related functions.

def update_sizes_all(tree):
    """Update sizes of all the nodes in the tree."""
    for node in tree.traverse('postorder'):
        update_size(node)


def update_sizes_from(node):
    """Update the sizes from the given node to the root of the tree."""
    while node is not None:
        update_size(node)
        node = node.up


def update_size(node):
    """Update the size of the given node."""
    sumdists, nleaves = get_size(node.children)
    dx = float(node.props.get('dist', 0 if node.up is None else 1)) + sumdists
    node.size = (dx, max(1, nleaves))


cdef (double, double) get_size(nodes):
    """Return the size of all the nodes stacked."""
    # The size of a node is (sumdists, nleaves) with sumdists the dist to
    # its furthest leaf (including itself) and nleaves its number of leaves.
    cdef double sumdists, nleaves

    sumdists = 0
    nleaves = 0
    for node in nodes:
        sumdists = max(sumdists, node.size[0])
        nleaves += node.size[1]

    return sumdists, nleaves
