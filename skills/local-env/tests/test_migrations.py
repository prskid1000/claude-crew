"""Unit tests for scripts/migrations.py: classification of sample changelog diffs (light, heavy, mixed) and revert plans.
  python -X utf8 skills/local-env/tests/test_migrations.py      (needs git; builds throwaway repos in a temp folder)
"""
import json, os, shutil, subprocess, sys, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, '..', 'scripts', 'migrations.py')
CL = 'api/src/main/resources/config/liquibase/changelog'
HEAD = ('<?xml version="1.0" encoding="utf-8"?>\n<databaseChangeLog xmlns="http://www.liquibase.org/xml/ns/dbchangelog">\n')
TAIL = '</databaseChangeLog>\n'


def xml(*changesets):
    return HEAD + ''.join(changesets) + TAIL


def cs(id_, body, rollback=None, attrs='', pre=''):
    rb = '' if rollback is None else (f'<rollback>{rollback}</rollback>' if rollback else '<rollback/>')
    return f'  <changeSet id="{id_}" author="dev"{attrs}>{pre}{body}{rb}</changeSet>\n'


TAG = lambda t: cs(f'{t}-0', f'<tagDatabase tag="{t}"/>')


def run(*a):
    p = subprocess.run([sys.executable, '-X', 'utf8', SCRIPT, *a], capture_output=True, text=True, encoding='utf-8')
    if p.returncode:
        raise AssertionError(p.stderr)
    return json.loads(p.stdout)


class Repo:
    def __init__(self):
        self.d = tempfile.mkdtemp(prefix='mig-test-')
        self.g('init', '-q', '-b', 'main'); self.g('config', 'user.email', 't@t'); self.g('config', 'user.name', 't')
        self.write(f'{CL}/20260101000000_base.xml', xml(TAG('20260101000000'), cs('20260101000000-1', '<createTable tableName="orders"><column name="id" type="BIGINT"/><column name="qty" type="INT"/></createTable>')))
        self.write('api/src/main/java/App.java', 'class App {}')
        self.commit('base')

    def g(self, *a):
        return subprocess.run(['git', '-C', self.d, *a], capture_output=True, text=True, check=True).stdout.strip()

    def write(self, rel, text):
        p = os.path.join(self.d, *rel.split('/'))
        os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, 'w', encoding='utf-8', newline='\n').write(text)

    def commit(self, msg):
        self.g('add', '-A'); self.g('commit', '-q', '-m', msg); return self.g('rev-parse', 'HEAD')

    def branch(self, name, files, base='main'):
        self.g('checkout', '-q', '-b', name, base)
        for rel, text in files.items():
            if text is None:
                os.remove(os.path.join(self.d, *rel.split('/')))
            else:
                self.write(rel, text)
        sha = self.commit(name); self.g('checkout', '-q', 'main'); return sha

    def classify(self, sha, save=None, cfg=None):
        a = ['classify', '--repo', self.d, '--base', 'main', '--head', sha]
        if save:
            a += ['--save', save]
        if cfg:
            p = os.path.join(self.d, '..', os.path.basename(self.d) + '-cfg.json'); json.dump(cfg, open(p, 'w')); a += ['--config', p]
        return run(*a)


LIGHT_FILE = xml(TAG('20260201000000'),
                 cs('20260201000000-1', '<addColumn tableName="orders"><column name="note" type="VARCHAR(80)"/></addColumn>',
                    '<dropColumn tableName="orders" columnName="note"/>', pre='<preConditions onFail="MARK_RAN"><not><columnExists tableName="orders" columnName="note"/></not></preConditions>'),
                 cs('20260201000000-2', '<createTable tableName="order_status"><column name="id" type="INT"/><column name="code" type="VARCHAR(20)"/></createTable>'),
                 cs('20260201000000-3', '<insert tableName="order_status"><column name="id" valueNumeric="1"/><column name="code" value="NEW"/></insert>',
                    '<delete tableName="order_status"><where>id = 1</where></delete>'),
                 cs('20260201000000-4', '<update tableName="orders"><column name="qty" valueNumeric="0"/><where>qty IS NULL AND id IN (SELECT id FROM orders WHERE 1=0)</where></update>',
                    '<sql>UPDATE orders SET qty = NULL WHERE 1=0</sql>'),
                 cs('20260201000000-5', '<sql>ALTER TABLE orders ADD INDEX ix_orders_qty (qty)</sql>', '<sql>ALTER TABLE orders DROP INDEX ix_orders_qty</sql>'))


class Classify(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.r = Repo()

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.r.d, ignore_errors=True)

    def test_light(self):
        sha = self.r.branch('light', {f'{CL}/20260201000000_light.xml': LIGHT_FILE})
        res = self.r.classify(sha)
        self.assertEqual(res['class'], 'light', res['reasons'])
        self.assertEqual([c['id'] for c in res['changesets']], [f'20260201000000-{i}' for i in range(6)])
        self.assertEqual(res['changesets'][0]['file'], 'config/liquibase/changelog/20260201000000_light.xml')
        self.assertTrue(res['changesets'][1]['guarded'])
        self.assertIn('order_status', res['changesets'][2]['creates'])

    def test_no_migrations(self):
        sha = self.r.branch('code-only', {'api/src/main/java/App.java': 'class App { int x; }'})
        self.assertEqual(self.r.classify(sha)['class'], 'none')

    def heavy(self, name, body, rule, rollback='', **kw):
        sha = self.r.branch(name, {f'{CL}/20260301000000_{name}.xml': xml(TAG('20260301000000'), cs('20260301000000-1', body, rollback, **kw))})
        res = self.r.classify(sha)
        self.assertEqual(res['class'], 'heavy', f'{name}: {res}')
        self.assertEqual(res['changesets'][1]['rule'], rule, res['reasons'])
        return res

    def test_heavy_rules(self):
        self.heavy('dropcol', '<dropColumn tableName="orders" columnName="qty"/>', 'drop-data', '<addColumn tableName="orders"><column name="qty" type="INT"/></addColumn>')
        self.heavy('droptable', '<dropTable tableName="orders"/>', 'drop-data', '<sql>CREATE TABLE orders (id BIGINT)</sql>')
        self.heavy('unbounded', '<update tableName="orders"><column name="qty" valueNumeric="0"/></update>', 'unbounded', '<sql>UPDATE orders SET qty = NULL WHERE 1=0</sql>')
        self.heavy('delrows', '<delete tableName="orders"><where>qty = 0</where></delete>', 'delete-rows', '<sql>SELECT 1</sql>')
        self.heavy('emptyrb', '<addColumn tableName="orders"><column name="x" type="INT"/></addColumn>', 'empty-rollback', '')
        self.heavy('norb', '<sql>ALTER TABLE orders ADD COLUMN y INT</sql>', 'no-rollback', None)
        self.heavy('always', '<sql>ALTER TABLE orders ADD COLUMN z INT</sql>', 'runs-always', '<sql>ALTER TABLE orders DROP INDEX z</sql>', attrs=' runAlways="true"')
        self.heavy('rawsql', '<sql>ALTER TABLE orders MODIFY qty BIGINT</sql>', 'raw-sql', '<sql>ALTER TABLE orders MODIFY qty INT</sql>')
        self.heavy('retype', '<modifyDataType tableName="orders" columnName="qty" newDataType="SMALLINT"/>', 'retype', '<modifyDataType tableName="orders" columnName="qty" newDataType="INT"/>')
        self.heavy('loaddata', '<loadData tableName="orders" file="x.csv"/>', 'bulk-file', '<sql>SELECT 1</sql>')

    def test_drop_own_is_light(self):
        sha = self.r.branch('dropown', {f'{CL}/20260401000000_own.xml': xml(
            cs('20260401000000-1', '<addColumn tableName="orders"><column name="tmp" type="INT"/></addColumn>'),
            cs('20260401000000-2', '<dropColumn tableName="orders" columnName="tmp"/>', '<addColumn tableName="orders"><column name="tmp" type="INT"/></addColumn>'))})
        self.assertEqual(self.r.classify(sha)['class'], 'light')

    def test_edit_applied_and_raw_file(self):
        base = f'{CL}/20260101000000_base.xml'
        sha = self.r.branch('edit', {base: xml(TAG('20260101000000'), cs('20260101000000-1', '<createTable tableName="orders"><column name="id" type="BIGINT"/></createTable>'))})
        res = self.r.classify(sha)
        self.assertEqual((res['class'], res['changesets'][0]['rule']), ('heavy', 'edits-applied'))
        sha = self.r.branch('rawfile', {'api/src/main/resources/db/migrations/V2__x.sql': 'UPDATE orders SET qty = 1;'})
        res = self.r.classify(sha)
        self.assertEqual((res['class'], res['changesets'][0]['rule']), ('heavy', 'raw-sql-file'))

    def test_mixed_is_heavy_and_names_the_changeset(self):
        sha = self.r.branch('mixed', {f'{CL}/20260501000000_mixed.xml': xml(
            TAG('20260501000000'), cs('20260501000000-1', '<addColumn tableName="orders"><column name="ok" type="INT"/></addColumn>'),
            cs('20260501000000-2', '<delete tableName="orders"/>', '<sql>SELECT 1</sql>'))})
        res = self.r.classify(sha)
        self.assertEqual(res['class'], 'heavy')
        self.assertEqual([c['class'] for c in res['changesets']], ['light', 'light', 'heavy'])
        self.assertEqual(res['reasons'], ['config/liquibase/changelog/20260501000000_mixed.xml::20260501000000-2 unbounded: unbounded delete on orders (no WHERE)'])

    def test_formatted_sql_and_yaml(self):
        sql = ('--liquibase formatted sql\n--changeset dev:20260601000000-1\nALTER TABLE orders ADD COLUMN s INT;\n'
               '--rollback ALTER TABLE orders DROP COLUMN s;\n--changeset dev:20260601000000-2\nDELETE FROM orders WHERE id > 5;\n--rollback not required\n')
        sha = self.r.branch('fsql', {f'{CL}/20260601000000_x.sql': sql})
        res = self.r.classify(sha)
        self.assertEqual([(c['class'], c['rule']) for c in res['changesets']], [('light', ''), ('heavy', 'empty-rollback')])
        yml = ('databaseChangeLog:\n- changeSet:\n    id: 20260701000000-1\n    author: dev\n    changes:\n    - addColumn:\n        tableName: orders\n'
               '        columns:\n        - column:\n            name: y\n            type: INT\n')
        sha = self.r.branch('yml', {f'{CL}/20260701000000_x.yaml': yml})
        res = self.r.classify(sha)
        try:
            import yaml  # noqa: F401
            self.assertEqual(res['class'], 'light', res)
        except ImportError:
            self.assertEqual(res['changesets'][0]['rule'], 'unparsed')

    def test_rules_are_configurable(self):
        sha = self.r.branch('cfg', {f'{CL}/20260801000000_x.xml': xml(cs('20260801000000-1', '<delete tableName="orders"><where>id = 1</where></delete>', '<sql>SELECT 1</sql>'))})
        self.assertEqual(self.r.classify(sha)['class'], 'heavy')
        self.assertEqual(self.r.classify(sha, cfg={'referenceTables': '^orders$'})['class'], 'light')
        res = self.r.classify(sha, cfg={'extraRules': [{'id': 'no-orders', 'table': '^orders$', 'class': 'heavy', 'why': 'org rule'}], 'referenceTables': '^orders$'})
        self.assertEqual(res['changesets'][0]['rule'], 'no-orders')


class Plan(unittest.TestCase):
    def setUp(self):
        self.r = Repo(); self.tmp = tempfile.mkdtemp(prefix='mig-plan-')

    def tearDown(self):
        shutil.rmtree(self.r.d, ignore_errors=True); shutil.rmtree(self.tmp, ignore_errors=True)

    def manifest(self, name, sha):
        d = os.path.join(self.tmp, name); self.r.classify(sha, save=d); return os.path.join(d, 'manifest.json')

    def test_revert_only_the_leaving_layer_newest_first(self):
        a = self.manifest('a', self.r.branch('a', {f'{CL}/20260201000000_light.xml': LIGHT_FILE}))
        b = self.manifest('b', self.r.branch('b', {f'{CL}/20260901000000_b.xml': xml(cs('20260901000000-1', '<createIndex tableName="orders" indexName="ix_q"><column name="qty"/></createIndex>'))}))
        out = os.path.join(self.tmp, 'out')
        res = run('plan', '--leaving', a, '--staying', b, '--repo', self.r.d, '--out', out)
        self.assertEqual([c['id'] for c in res['revert']], [f'20260201000000-{i}' for i in (5, 4, 3, 2, 1, 0)])
        self.assertEqual(res['blocked'], [])
        cut = open(os.path.join(res['searchPath'], 'config', 'liquibase', 'changelog', '20260201000000_light.xml'), encoding='utf-8').read()
        self.assertEqual(cut.count('<changeSet'), 6)
        self.assertIn('config/liquibase/changelog/20260201000000_light.xml', open(os.path.join(res['searchPath'], 'localenv-revert.xml')).read())

    def test_dependent_layer_blocks(self):
        a = self.manifest('a', self.r.branch('a', {f'{CL}/20260201000000_light.xml': LIGHT_FILE}))
        c = self.manifest('c', self.r.branch('c', {f'{CL}/20261001000000_c.xml': xml(cs('20261001000000-1',
            '<addForeignKeyConstraint baseTableName="orders" baseColumnNames="qty" constraintName="fk_orders_qty" referencedTableName="order_status" referencedColumnNames="id"/>'))}))
        res = run('plan', '--leaving', a, '--staying', c)
        self.assertEqual(res['blocked'][0]['uses'], ['order_status', 'order_status.id'])

    def test_changesets_still_in_release_are_kept(self):
        sha = self.r.branch('a', {f'{CL}/20260201000000_light.xml': LIGHT_FILE})
        a = self.manifest('a', sha)
        self.r.g('merge', '-q', '--no-ff', '-m', 'merged', 'a')   # the layer was merged into the target: nothing to revert
        res = run('plan', '--leaving', a, '--repo', self.r.d)
        self.assertEqual((res['count'], len(res['kept'])), (0, 6))

    def test_replaced_layer_reverts_only_what_changed(self):
        a1 = self.manifest('a1', self.r.branch('a', {f'{CL}/20260201000000_light.xml': LIGHT_FILE}))
        self.r.g('checkout', '-q', 'a')
        self.r.write(f'{CL}/20260201000000_light.xml', LIGHT_FILE.replace('VARCHAR(80)', 'VARCHAR(120)'))
        a2sha = self.r.commit('a v2'); self.r.g('checkout', '-q', 'main')
        a2 = self.manifest('a2', a2sha)
        res = run('plan', '--leaving', a1, '--staying', a2)
        self.assertEqual([c['id'] for c in res['revert']], ['20260201000000-1'])


if __name__ == '__main__':
    unittest.main(verbosity=1, warnings='ignore')
