import Home from '../../../../views/Home.vue';

// Compile smoke-test: importing Home.vue compiles the SFC and its UMI imports,
// so this fails loudly if the patch breaks Home's imports or template.
describe('Home.vue — UMI composer integration', () => {
  it('compiles and registers the UMI home components', () => {
    expect(Home).toBeTruthy();
    expect(Object.keys(Home.components)).toEqual(
      expect.arrayContaining(['UmiHomeComposer', 'UmiInboxLinks'])
    );
  });
});
