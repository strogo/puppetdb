step "Verify we've been talking to the correct database" do

  # The goal here is just to try to make sure we've tested
  #  what we think we've tested.  e.g., if we intended to
  #  run the tests against postgres, let's try to make
  #  sure that they didn't accidentally get run against the
  #  embedded db and vice-versa.  (The tests could theoretically
  #  all pass even if they were running against a different
  #  database than we'd intended.)

  if (options[:puppetdb_database] == 'postgres')

    # If we're running w/postgres, we're going to use some hacky raw SQL
    #  and shell magic to validate that the database schema version is the
    #  same in the database as in the source code, and that the certnames
    #  table contains exactly the list of hostnames as the hosts array.
    # If so, we'll assume that puppetdb was communicating with postgres
    #  successfully during the test run. (These conditions were chosen
    #  somewhat arbitrarily.)

    step "Validate database schema version" do
      db_migration_version = on(database, "PGPASSWORD=puppet psql -h localhost -U postgres -d puppetdb --tuples-only -c \"SELECT max(version) from schema_migrations\" |tr -d \" \" |grep -v \"^\s*$\"").stdout.strip

      source_migration_version = on(database, "unzip -p /usr/share/puppetdb/puppetdb.jar com/puppetlabs/puppetdb/scf/migrate.clj | sed '/defn schema.version/,$d' |sed '1,/def migrations/d' |grep -v \"^\s*$\" |tail -n 1 |awk '{print $1}'").stdout.strip

      assert_equal(db_migration_version, source_migration_version,
                   "Expected migration version from source code '#{source_migration_version}' " +
                       "to match migration version found in postgres database '#{db_migration_version}'")
    end


    step "Validate the contents of the certname table" do
      db_hostnames_str = on(database, "PGPASSWORD=puppet psql -h localhost -U postgres -d puppetdb --tuples-only -c \"SELECT name from certnames\" |grep -v \"^\s*$\"").stdout.strip
      db_hostnames = Set.new(db_hostnames_str.split.map { |x| x.strip })
      acceptance_hostnames = Set.new(hosts.map { |host| host.node_name })
      assert_equal(acceptance_hostnames, db_hostnames, "Expected hostnames from certnames table to match the ones known to the acceptance harness")
    end


  else
    # If we're running w/the embedded db, we're just going to check to make
    #  sure that postgres is not installed.  Assuming it's not, then if the
    #  tests passed, by deductive reasoning the embedded DB *MUST* be working
    #  OK.  I mean... right? ;)

    ["postgresql", "postgresql-server"].each do |pkg|
      result = on(database, "puppet resource package #{pkg} |grep \"ensure\" |egrep \"(absent)|(purged)\" |wc -l").stdout.strip.to_i
      assert_equal(1, result, "Expected 'ensure => purged' for package '#{pkg}'")
    end

  end
end
