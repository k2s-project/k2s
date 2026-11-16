// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package print

import (
	"encoding/json"
	"errors"
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/k2s-project/k2s/internal/core/addons"
	"github.com/k2s-project/k2s/internal/test/reflection"
	"github.com/stretchr/testify/mock"
)

type mockObject struct {
	mock.Mock
}

func (m *mockObject) Println(t ...any) {
	m.Called(t)
}

func (m *mockObject) SPrintTable(separator string, table [][]string) (string, error) {
	args := m.Called(separator, table)

	return args.String(0), args.Error(1)
}

func (m *mockObject) PrintLeveledTreeListItems(rootText string, items []struct {
	Level int
	Text  string
}) {
	m.Called(rootText, items)
}

func (m *mockObject) PrintCyanFg(text string) string {
	args := m.Called(text)

	return args.String(0)
}

func TestPrintPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "addons print Unit Tests", Label("unit", "ci", "addons", "print"))
}

var _ = Describe("print pkg", func() {
	Describe("PrintAddonsUserFriendly", func() {
		When("addon printing error occurred", func() {
			It("returns the error", func() {
				expectedError := errors.New("oops")

				printerMock := &mockObject{}
				printerMock.On(reflection.GetFunctionName(printerMock.Println), mock.Anything)
				printerMock.On(reflection.GetFunctionName(printerMock.SPrintTable), " # ", mock.Anything).Return("", expectedError)

				sut := NewAddonsPrinter(printerMock)

				err := sut.PrintAddonsUserFriendly([]EnabledAddon{}, addons.Addons{})

				Expect(err).To(MatchError(expectedError))

				printerMock.AssertExpectations(GinkgoT())
			})
		})

		When("successful", func() {
			It("prints leveled list", func() {
				tableString := "addon1 # this is addon 1\naddon2 # this is addon 2\n$---$\naddon3 # this is addon 3\n   implementation1 # this is implementation 1 of addon 3"

				printerMock := &mockObject{}
				printerMock.On(reflection.GetFunctionName(printerMock.Println), mock.Anything)
				printerMock.On(reflection.GetFunctionName(printerMock.SPrintTable), " # ", mock.Anything).Return(tableString, nil)
				printerMock.On(reflection.GetFunctionName(printerMock.PrintLeveledTreeListItems), "Addons", mock.MatchedBy(func(items []struct {
					Level int
					Text  string
				}) bool {
					return len(items) == 6 &&
						items[0].Level == 0 && items[0].Text == "Enabled" &&
						items[1].Level == 1 && items[1].Text == "addon1 # this is addon 1" &&
						items[2].Level == 1 && items[2].Text == "addon2 # this is addon 2" &&
						items[3].Level == 0 && items[3].Text == "Disabled" &&
						items[4].Level == 1 && items[4].Text == "addon3 # this is addon 3" &&
						items[5].Level == 2 && items[5].Text == " implementation1 # this is implementation 1 of addon 3"
				}))

				sut := NewAddonsPrinter(printerMock)

				err := sut.PrintAddonsUserFriendly([]EnabledAddon{}, addons.Addons{})

				Expect(err).ToNot(HaveOccurred())

				printerMock.AssertExpectations(GinkgoT())
			})
		})
	})

	Describe("PrintAddonsAsJson", func() {
		It("prints addons as json", func() {
			enabledAddons := []EnabledAddon{{Name: "a1", Description: "d1", Implementations: []string{"i1"}}, {Name: "a3", Description: "d3"}}
			allAddons := addons.Addons{
				addons.Addon{Metadata: addons.AddonMetadata{Name: "a1", Description: "d1"}, Spec: addons.AddonSpec{Implementations: []addons.Implementation{{Name: "i1"}, {Name: "i2"}}}},
				addons.Addon{Metadata: addons.AddonMetadata{Name: "a2", Description: "d2"}},
				addons.Addon{Metadata: addons.AddonMetadata{Name: "a3", Description: "d3"}},
			}

			printerMock := &mockObject{}
			printerMock.On(reflection.GetFunctionName(printerMock.Println), mock.MatchedBy(func(m []any) bool {
				jsonString := m[0].(string)

				var list *printList
				err := json.Unmarshal([]byte(jsonString), &list)

				Expect(err).ToNot(HaveOccurred())
				Expect(list.EnabledAddons).To(ConsistOf(
					SatisfyAll(
						HaveField("Name", "a1"), HaveField("Description", "d1"), HaveField("Implementations", []Implementation{{Name: "i1"}}),
					),
					SatisfyAll(
						HaveField("Name", "a3"), HaveField("Description", "d3"),
					),
				))
				Expect(list.DisabledAddons).To(ConsistOf(
					SatisfyAll(
						HaveField("Name", "a1"), HaveField("Description", "d1"), HaveField("Implementations", []Implementation{{Name: "i2"}}),
					),
					SatisfyAll(
						HaveField("Name", "a2"), HaveField("Description", "d2"),
					),
				))

				return true
			})).Once()

			sut := NewAddonsPrinter(printerMock)

			err := sut.PrintAddonsAsJson(enabledAddons, allAddons)

			Expect(err).ToNot(HaveOccurred())

			printerMock.AssertExpectations(GinkgoT())
		})
	})

	Describe("toPrintList", func() {
		It("builds a print list based on enabled/disabled addons", func() {
			enabledAddons := []EnabledAddon{
				{Name: "a1", Description: "d2", Implementations: []string{"i1"}},
				{Name: "a3", Description: "d3"},
			}
			allAddons := addons.Addons{
				addons.Addon{Metadata: addons.AddonMetadata{Name: "a1", Description: "d1"}, Spec: addons.AddonSpec{Implementations: []addons.Implementation{{Name: "i1"}, {Name: "i2"}}}},
				addons.Addon{Metadata: addons.AddonMetadata{Name: "a2", Description: "d2"}},
				addons.Addon{Metadata: addons.AddonMetadata{Name: "a3", Description: "d3"}},
			}

			result := toPrintList(enabledAddons, allAddons)

			Expect(result.EnabledAddons).To(ConsistOf(
				SatisfyAll(
					HaveField("Name", "a1"), HaveField("Description", "d1"), HaveField("Implementations", []Implementation{{Name: "i1"}}),
				),
				SatisfyAll(
					HaveField("Name", "a3"), HaveField("Description", "d3"),
				),
			))
			Expect(result.DisabledAddons).To(ConsistOf(
				SatisfyAll(
					HaveField("Name", "a1"), HaveField("Description", "d1"), HaveField("Implementations", []Implementation{{Name: "i2"}}),
				),
				SatisfyAll(
					HaveField("Name", "a2"), HaveField("Description", "d2"),
				),
			))
		})
	})

	Describe("indentList", func() {
		When("error occurred", func() {
			It("returns the error", func() {
				list := &printList{}
				expectedError := errors.New("oops")

				printerMock := &mockObject{}
				printerMock.On(reflection.GetFunctionName(printerMock.SPrintTable), " # ", mock.Anything).Return("", expectedError)

				sut := NewAddonsPrinter(printerMock)

				actual, err := sut.indentList(list)

				Expect(err).To(MatchError(expectedError))
				Expect(actual).To(BeNil())
			})
		})

		When("successful", func() {
			It("returns list", func() {
				list := &printList{}
				tableString := "A1 - D1\nA2 - D2\nA3 - D3\n"

				printerMock := &mockObject{}
				printerMock.On(reflection.GetFunctionName(printerMock.SPrintTable), " # ", mock.Anything).Return(tableString, nil)

				sut := NewAddonsPrinter(printerMock)

				actual, err := sut.indentList(list)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(ConsistOf("A1 - D1", "A2 - D2", "A3 - D3"))
			})
		})
	})

	Describe("createRows", func() {
		It("creates rows", func() {
			addons := []Addon{
				{Name: "a1", Description: "d1", Implementations: []Implementation{{Name: "i1", Description: "d1"}}},
				{Name: "a2", Description: "d2"},
				{Name: "a3", Description: "d3"},
			}

			printerMock := &mockObject{}
			printerMock.On(reflection.GetFunctionName(printerMock.PrintCyanFg), "a1").Return("a1*")
			printerMock.On(reflection.GetFunctionName(printerMock.PrintCyanFg), "a2").Return("a2*")
			printerMock.On(reflection.GetFunctionName(printerMock.PrintCyanFg), "a3").Return("a3*")
			printerMock.On(reflection.GetFunctionName(printerMock.PrintCyanFg), "i1").Return("i1*")

			sut := NewAddonsPrinter(printerMock)

			actual := sut.createRows(addons)

			Expect(actual).To(ConsistOf(
				[]string{" a1*", "d1"},
				[]string{" a2*", "d2"},
				[]string{" a3*", "d3"},
				[]string{"   i1*", "d1"},
			))
		})
	})

	Describe("buildLeveledList", func() {
		Context("nil addons list with enabled node only", func() {
			It("builds the correct list", func() {
				actual := buildLeveledList(nil)

				Expect(actual).To(HaveLen(1))
				Expect(actual[0].Level).To(Equal(0))
				Expect(actual[0].Text).To(Equal("Enabled"))
			})
		})

		Context("empty addons list with enabled node only", func() {
			It("builds the correct list", func() {
				actual := buildLeveledList([]string{})

				Expect(actual).To(HaveLen(1))
				Expect(actual[0].Level).To(Equal(0))
				Expect(actual[0].Text).To(Equal("Enabled"))
			})
		})

		Context("addon separator-only list with enabled/disabled node", func() {
			It("builds the correct list", func() {
				actual := buildLeveledList([]string{separator})

				Expect(actual).To(HaveLen(2))
				Expect(actual[0].Level).To(Equal(0))
				Expect(actual[0].Text).To(Equal("Enabled"))
				Expect(actual[1].Level).To(Equal(0))
				Expect(actual[1].Text).To(Equal("Disabled"))
			})
		})

		Context("enabled/disabled addons", func() {
			It("builds the correct list", func() {
				addons := []string{
					"addon1",
					separator,
					"addon2",
					"   implementation1 # description1"}

				actual := buildLeveledList(addons)

				Expect(actual).To(HaveLen(5))
				Expect(actual[0].Level).To(Equal(0))
				Expect(actual[0].Text).To(Equal("Enabled"))
				Expect(actual[1].Level).To(Equal(1))
				Expect(actual[1].Text).To(Equal("addon1"))
				Expect(actual[2].Level).To(Equal(0))
				Expect(actual[2].Text).To(Equal("Disabled"))
				Expect(actual[3].Level).To(Equal(1))
				Expect(actual[3].Text).To(Equal("addon2"))
				Expect(actual[4].Level).To(Equal(2))
				Expect(actual[4].Text).To(Equal(" implementation1 # description1"))
			})
		})
	})
})
