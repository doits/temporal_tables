# frozen_string_literal: true

require 'spec_helper'

describe TemporalTables::Whodunnit do
  before { Current.user = 'Agatha' }

  it 'records updated_by without building the history class' do
    familiar = Familiar.create!(name: 'Greebo')
    Current.user = 'Magrat'
    familiar.update!(name: 'Greebo the Second')

    expect(familiar.reload.updated_by).to eq('Magrat')
    expect(ActiveRecord::Base.connection.select_values('select updated_by from familiars_h order by eff_from'))
      .to eq(%w[Agatha Magrat])
    expect(Object.const_defined?(:FamiliarHistory)).to be(false)
  end
end
